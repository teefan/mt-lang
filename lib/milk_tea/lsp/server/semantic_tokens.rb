# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerSemanticTokens
        private

      def handle_semantic_tokens_full(params)
        uri = params.dig('textDocument', 'uri')
        return { data: [] } unless uri

        total_start = monotonic_time

        content = @workspace.get_content(uri)
        cache_key = content.hash
        cached = @semantic_tokens_cache[uri]
        if cached && cached[:content_hash] == cache_key
          elapsed = elapsed_ms(total_start)
          short_uri = shorten_uri(uri) || uri
          log_perf_breakdown('textDocument/semanticTokens/full', elapsed,
                             "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} cache=hit data_len=#{cached[:data].length}")
          return { data: cached[:data] }
        end

        tokens_start = monotonic_time
        tokens = @workspace.get_tokens(uri) || []
        tokens_ms = elapsed_ms(tokens_start)

        facts_start = monotonic_time
        facts = @workspace.get_facts(uri, allow_last_good_fallback: semantic_tokens_allow_last_good_fallback?(uri))
        facts_ms = elapsed_ms(facts_start)

        build_start = monotonic_time
        semantic_entries = build_semantic_token_entries(tokens, facts)
        build_ms = elapsed_ms(build_start)

        encode_start = monotonic_time
        data = encode_semantic_tokens(semantic_entries)
        encode_ms = elapsed_ms(encode_start)

        @semantic_tokens_cache[uri] = { content_hash: cache_key, data: data }

        result_id = next_semantic_token_result_id(uri)
        @semantic_tokens_delta_cache[uri] = {
          result_id: result_id,
          content_hash: cache_key,
          entries: semantic_entries,
        }

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        log_perf_breakdown('textDocument/semanticTokens/full', elapsed,
                           "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} cache=miss tokens=#{tokens.length} entries=#{semantic_entries.length} data_len=#{data.length} facts=on stages_ms=tokens:#{tokens_ms},facts:#{facts_ms},build:#{build_ms},encode:#{encode_ms}")

        { data: data }
      rescue StandardError => e
        warn "Error in semanticTokens/full handler: #{e.message}"
        { data: [] }
      end

      def handle_semantic_tokens_delta(params)
        uri = params.dig('textDocument', 'uri')
        previous_result_id = params['previousResultId']
        return handle_semantic_tokens_full(params) unless uri && previous_result_id

        cached = @semantic_tokens_delta_cache[uri]
        unless cached && cached[:result_id] == previous_result_id
          return handle_semantic_tokens_full(params)
        end

        content = @workspace.get_content(uri)
        cache_key = content.hash
        if cached[:content_hash] == cache_key
          return { resultId: cached[:result_id], edits: [] }
        end

        tokens = @workspace.get_tokens(uri) || []
        facts = @workspace.get_facts(uri, allow_last_good_fallback: semantic_tokens_allow_last_good_fallback?(uri))
        new_entries = build_semantic_token_entries(tokens, facts)

        new_result_id = next_semantic_token_result_id(uri)
        @semantic_tokens_delta_cache[uri] = {
          result_id: new_result_id,
          content_hash: cache_key,
          entries: new_entries,
        }

        edits = compute_semantic_tokens_edits(cached[:entries], new_entries)
        { resultId: new_result_id, edits: edits }
      rescue StandardError => e
        warn "Error in semanticTokens/full/delta handler: #{e.message}"
        handle_semantic_tokens_full(params)
      end

      def handle_semantic_tokens_range(params)
        uri = params.dig("textDocument", "uri")
        range = params["range"]
        return { data: [] } unless uri && range

        content = @workspace.get_content(uri)
        return { data: [] } unless content

        tokens = @workspace.get_tokens(uri) || []
        return { data: [] } if tokens.empty?

        start_line = range.dig("start", "line") + 1
        end_line = range.dig("end", "line") + 1

        range_tokens = tokens.select do |t|
          t.line >= start_line && t.line <= end_line &&
            ![:newline, :indent, :dedent, :eof].include?(t.type)
        end

        facts = @workspace.get_facts(uri, allow_last_good_fallback: semantic_tokens_allow_last_good_fallback?(uri))
        semantic_entries = build_semantic_token_entries(range_tokens, facts)

        entries_in_range = semantic_entries.select do |entry|
          entry[:line] >= start_line && entry[:line] <= end_line
        end

        data = encode_semantic_tokens(entries_in_range)
        { data: data }
      rescue StandardError => e
        warn "Error in semanticTokens/range handler: #{e.message}"
        { data: [] }
      end

      def build_semantic_token_entries(tokens, facts = nil)
        # Precompute line → non-trivia tokens index so non_trivia_tokens_on_line
        # is O(1) per call instead of O(n), turning the overall build from O(n²) to O(n).
        trivia_types = Set[:newline, :indent, :dedent, :eof]
        @tokens_by_line_cache = Hash.new { |h, k| h[k] = [] }
        tokens.each { |t| @tokens_by_line_cache[t.line] << t unless trivia_types.include?(t.type) }
        @attribute_name_semantic_overrides = build_attribute_name_semantic_overrides(tokens, facts)

        entries = []

        tokens.each_with_index do |tok, index|
          next if [:newline, :indent, :dedent, :eof].include?(tok.type)

          if tok.type == :fstring
            next if embedded_heredoc_token?(tok)
            fstring_interpolation_entries(tok, facts).each { |e| entries << e }
            next
          end

          semantic_type, modifiers = classify_semantic_token(tokens, index, facts)
          next unless semantic_type

          token_semantic_entries(tok, semantic_type, modifiers).each { |entry| entries << entry }
        end

        entries.sort_by { |entry| [entry[:line], entry[:start_char]] }
      ensure
        @tokens_by_line_cache = nil
        @attribute_name_semantic_overrides = nil
      end

      def fstring_interpolation_entries(fstring_tok, facts)
        parts = fstring_tok.literal
        return [{ line: fstring_tok.line - 1, start_char: fstring_tok.column - 1, length: fstring_tok.lexeme.length, type: :string, modifiers: [] }] unless parts.is_a?(Array)

        result = []
        fstr_line = fstring_tok.line - 1   # 0-indexed
        fstr_col0 = fstring_tok.column - 1 # 0-indexed start of `f`
        cursor = fstr_col0

        parts.each do |part|
          next unless part[:kind] == :expr

          # part[:column] is 1-indexed column of the first char of the expression source
          # (i.e. the char right after `#{`).
          expr_col0  = part[:column] - 1          # 0-indexed
          hash_col0  = expr_col0 - 2              # 0-indexed position of `#`

          raw_len       = part[:source].length + (part[:format_spec] ? 1 + part[:format_spec].length : 0)
          rbrace_col0   = expr_col0 + raw_len     # 0-indexed position of `}`

          # :string for everything from cursor up to (but not including) `#`
          text_len = hash_col0 - cursor
          result << { line: fstr_line, start_char: cursor, length: text_len, type: :string, modifiers: [] } if text_len > 0

          # classified entries for the expression source only (not format spec).
          source = part[:source]
          unless source.nil? || source.strip.empty?
            begin
              sub_tokens = interpolation_expression_tokens(part)
              sub_tokens.each_with_index do |sub_tok, i|
                sem_type, modifiers = classify_semantic_token(sub_tokens, i, facts)
                next unless sem_type
                result << {
                  line: sub_tok.line - 1,
                  start_char: sub_tok.column - 1,
                  length: sub_tok.lexeme.length,
                  type: sem_type,
                  modifiers: modifiers
                }
              end
            rescue MilkTea::LexError
              # Fall back to string coloring for malformed expression.
              result << {
                line: fstr_line,
                start_char: expr_col0,
                length: source.length,
                type: :string,
                modifiers: [],
              }
            end
          end

          # classified entries for format spec (if present), excluding the
          # delimiter token so TextMate interpolation punctuation can style it.
          if part[:format_spec]
            spec_col0 = expr_col0 + source.length
            # Format spec content (e.g., ".0", "3", ".5f") as individual token-like entries.
            # Treat it as lexable content or just string for simplicity.
            spec = part[:format_spec]
            unless spec.empty?
              begin
                spec_tokens = MilkTea::Lexer.new(spec).lex
                                           .reject { |t| [:newline, :indent, :dedent, :eof].include?(t.type) }
                spec_tokens.each_with_index do |spec_tok, i|
                  spec_sem_type, spec_modifiers = classify_semantic_token(spec_tokens, i, facts)
                  next unless spec_sem_type
                  result << {
                    line: fstr_line,
                    start_char: spec_col0 + 1 + (spec_tok.column - 1),
                    length: spec_tok.lexeme.length,
                    type: spec_sem_type,
                    modifiers: spec_modifiers
                  }
                end
              rescue MilkTea::LexError
                # Fall back: treat spec as a number/string token.
                result << {
                  line: fstr_line,
                  start_char: spec_col0 + 1,
                  length: spec.length,
                  type: :number,
                  modifiers: []
                }
              end
            end
          end

          cursor = rbrace_col0 + 1
        end

        # :string for tail text + closing `"`
        fstr_end_col0 = fstr_col0 + fstring_tok.lexeme.length - 1
        tail_len = fstr_end_col0 - cursor + 1
        result << { line: fstr_line, start_char: cursor, length: tail_len, type: :string, modifiers: [] } if tail_len > 0

        result
      end

      def classify_semantic_token(tokens, index, facts = nil)
        tok = tokens[index]

        if tok.type == :identifier || namespace_keyword_token?(tokens, index)
          return classify_name_semantic(tok.lexeme, tokens, index, facts)
        end

        if [:string, :cstring].include?(tok.type)
          return [nil, []] if embedded_heredoc_token?(tok)

          return [:string, []]
        end

        if tok.type == :comment
          return [:comment, []]
        end

        if [:integer, :float].include?(tok.type)
          return [:number, []]
        end

        if KEYWORD_TOKEN_TYPES.include?(tok.type)
          return [:keyword, []]
        end

        if OPERATOR_TOKEN_TYPES.include?(tok.type)
          return [:operator, []]
        end

        [nil, []]
      end

      def embedded_heredoc_token?(token)
        return false unless [:string, :cstring, :fstring].include?(token.type)

        tag = token.lexeme[/\A(?:f|c)?<<-([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n/, 1]
        return false if tag.nil?

        %w[GLSL VERT FRAG COMP JSON JSONC SQL HTML].include?(tag)
      end

      def token_semantic_entries(token, semantic_type, modifiers)
        token.lexeme.split("\n", -1).each_with_index.filter_map do |segment, index|
          next if segment.empty?

          {
            line: token.line - 1 + index,
            start_char: index.zero? ? (token.column - 1) : 0,
            length: segment.length,
            type: semantic_type,
            modifiers: modifiers
          }
        end
      end

      def classify_name_semantic(name, tokens, index, facts = nil)
        tok = tokens[index]
        prev_tok = previous_non_trivia_token(tokens, index)
        next_tok = next_non_trivia_token(tokens, index + 1)
        parameter_declaration = parameter_declaration_token?(tokens, index)
        user_defined_function = facts ? facts.functions.key?(name) : lexically_declared_free_function_name?(tokens, name)

        if @attribute_name_semantic_overrides && (override = @attribute_name_semantic_overrides[[tok.line, tok.column]])
          return override
        end

        if (import_info = import_path_info_at(tokens, index, allow_keywords: true))
          modifiers = []
          modifiers << 'declaration' if import_info[:role] == :alias
          return [:namespace, modifiers]
        end

        return [:namespace, []] if module_declaration_path_token?(tokens, index, allow_keywords: true)

        if prev_tok && [:function, :fn, :proc].include?(prev_tok.type)
          return [:function, ['declaration']]
        end

        if prev_tok && [:struct, :union, :enum, :flags, :variant, :type, :opaque, :interface].include?(prev_tok.type)
          return [:type, ['declaration']]
        end

        if prev_tok&.type == :event
          return struct_event_declaration_token?(tokens, index) ? [:property, ['declaration']] : [:variable, ['declaration']]
        end

        if prev_tok&.type == :const
          return [:variable, ['declaration', 'readonly']]
        end

        if prev_tok && [:let, :var].include?(prev_tok.type)
          return [:variable, ['declaration']] unless next_tok&.type == :lparen
        end

        if prev_tok&.type == :for
          return [:variable, ['declaration']]
        end

        return [:variable, ['declaration']] if match_arm_binding_token?(tokens, index)
        return [:parameter, ['declaration']] if callable_parameter_declaration_token?(tokens, index)
        return [:property, ['declaration']] if variant_payload_field_declaration_token?(tokens, index)
        return [:property, ['declaration']] if field_declaration_token?(tokens, index)

        if facts
          return [:typeParameter, ['declaration']] if type_parameter_declaration_token?(facts, tokens, index)
          return [:typeParameter, []] if type_parameter_reference_token?(facts, tokens, index)
        end

        return [:property, []] if named_argument_label_token?(tokens, index) && named_argument_label_in_type_constructor?(tokens, index, facts)
        return [:parameter, []] if named_argument_label_token?(tokens, index)

        if facts && prev_tok&.type != :dot && (generic_binding = generic_function_lexical_binding_semantic(facts, tok))
          return generic_binding
        end

        if next_tok&.type == :dot && facts
          return [:type, []] if facts.types.key?(name)
          return [:type, []] if facts.interfaces.key?(name)
          return [:namespace, []] if facts.imports.key?(name)

          if (binding = local_semantic_value_binding(facts, tok, allow_same_line_future: parameter_declaration))
            return semantic_value_binding_entry(binding, declaration: binding.kind == :param && parameter_declaration)
          end

          if (binding = facts.values[name])
            return semantic_value_binding_entry(binding)
          end
        end

        if facts && (facts.types.key?(name) || facts.interfaces.key?(name)) && identifier_in_type_argument_position?(tokens, index)
          return [:type, []]
        end

        return [:enumMember, ['declaration']] if variant_enum_member_declaration?(tokens, index)

        if prev_tok&.type == :dot
          if facts
            module_binding = imported_module_binding_for_member(tokens, index, facts)
            if module_binding
              if module_binding.functions.key?(name)
                return [:function, []] if next_tok&.type == :lparen || specialized_call_with_type_args?(tokens, index)
                return [:function, []] if next_tok&.type == :lbracket
                return [:function, []] if imported_module_function_value_member_access_site?(facts, tokens, index)
                return [:property, []]
              end
              return [:type, []] if module_binding.types.key?(name)
              return [:type, []] if module_binding.interfaces.key?(name)
              if (value_binding = module_binding.values[name])
                modifiers = []
                modifiers << 'readonly' if value_binding.respond_to?(:mutable) && value_binding.mutable == false
                return [:variable, modifiers]
              end
              return [:namespace, []] if facts.imports.key?(name)
            end

            return [:property, []] if callable_field_member_access?(name, tokens, index, facts)
            return [:method, []] if static_type_member_access?(tokens, index, facts)
          end

          return [:enumMember, []] if type_name_member_access?(tokens, index, facts)
          return [:method, []] if next_tok&.type == :lparen || specialized_call_with_type_args?(tokens, index)
          return [:property, []]
        end

        if next_tok&.type == :lparen || specialized_call_with_type_args?(tokens, index)
          if facts && (resolved = resolved_call_callee_semantic(name, tok, parameter_declaration, facts))
            return resolved
          end

          return [:function, []] if user_defined_function

          modifiers = []
          modifiers << 'defaultLibrary' if BUILTIN_FUNCTION_NAMES.include?(name)
          if BUILTIN_ASSOCIATED_HOOK_NAMES.include?(name) && specialized_call_with_type_args?(tokens, index) && !user_defined_function
            modifiers << 'defaultLibrary'
          end
          return [:function, modifiers]
        end

        return [:function, []] if next_tok&.type == :lbracket && user_defined_function

        if facts && identifier_in_type_reference_position?(tokens, index)
          if facts.types.key?(name)
            modifiers = []
            modifiers << 'defaultLibrary' if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
            return [:type, modifiers]
          end
          return [:type, []] if facts.interfaces.key?(name)

          if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
            return [:type, ['defaultLibrary']]
          end
        end

        if facts

          if (binding = local_semantic_value_binding(facts, tok, allow_same_line_future: parameter_declaration))
            return semantic_value_binding_entry(binding, declaration: binding.kind == :param && parameter_declaration)
          end

          if facts.types.key?(name)
            modifiers = []
            modifiers << 'defaultLibrary' if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
            return [:type, modifiers]
          end
          return [:type, []] if facts.interfaces.key?(name)

          return [:namespace, []] if facts.imports.key?(name)

          if (binding = facts.values[name])
            return semantic_value_binding_entry(binding)
          end

          return [:function, []] if bare_function_value_identifier_site?(facts, tok)
        end

        if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
          return [:type, ['defaultLibrary']]
        end

        return [:function, ['defaultLibrary']] if bare_builtin_specialization?(name, tokens, index)

        [:variable, []]
      end

      def named_argument_label_token?(tokens, index)
        prev_tok = previous_non_trivia_token(tokens, index)
        next_tok = next_non_trivia_token(tokens, index + 1)
        next_tok&.type == :equal && prev_tok && [:lparen, :comma].include?(prev_tok.type)
      end

      def named_argument_label_in_type_constructor?(tokens, index, facts)
        return false unless facts

        opener_index = parameter_list_opener_index(tokens, index)
        return false unless opener_index

        callee_index = previous_non_trivia_token_index(tokens, opener_index)
        return false unless callee_index

        if tokens[callee_index].type == :rbracket
          lbracket_index = matching_opener_index(tokens, callee_index)
          return false unless lbracket_index
          callee_index = previous_non_trivia_token_index(tokens, lbracket_index)
        end

        return false unless callee_index && tokens[callee_index].type == :identifier

        callee_name = tokens[callee_index].lexeme
        return true if facts.types.key?(callee_name) || facts.interfaces.key?(callee_name)

        dot_index = previous_non_trivia_token_index(tokens, callee_index)
        return false unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return false unless receiver_index

        if tokens[receiver_index].type == :rbracket
          lbracket_index = matching_opener_index(tokens, receiver_index)
          return false unless lbracket_index
          receiver_index = previous_non_trivia_token_index(tokens, lbracket_index)
        end

        return false unless receiver_index && tokens[receiver_index].type == :identifier

        receiver_name = tokens[receiver_index].lexeme
        facts.types.key?(receiver_name) || facts.interfaces.key?(receiver_name)
      end

      def match_arm_binding_token?(tokens, index)
        prev_tok = previous_non_trivia_token(tokens, index)
        next_tok = next_non_trivia_token(tokens, index + 1)
        prev_tok&.type == :as && next_tok&.type == :colon
      end

      def field_declaration_token?(tokens, index)
        tok = tokens[index]
        return false unless tok&.type == :identifier
        return false unless first_non_trivia_token_on_line?(tokens, index)
        return false if parameter_declaration_token?(tokens, index)
        return false if match_arm_binding_token?(tokens, index)

        next_tok = next_non_trivia_token(tokens, index + 1)
        next_tok&.type == :colon
      end

      def struct_event_declaration_token?(tokens, index)
        tok = tokens[index]
        return false unless tok&.type == :identifier

        prev_tok = previous_non_trivia_token(tokens, index)
        return false unless prev_tok&.type == :event

        line_tokens = non_trivia_tokens_on_line(tokens, tok.line)
        line_start = line_tokens.first
        return false unless line_start && line_start.column > 1

        i = index - 1
        while i >= 0
          current = tokens[i]
          i -= 1
          next if [:newline, :indent, :dedent, :eof].include?(current.type)
          next if current.line == tok.line
          next if current.column >= line_start.column

          header_line_toks = non_trivia_tokens_on_line(tokens, current.line)
          return header_line_toks.first&.type == :struct
        end

        false
      end

      def variant_payload_field_declaration_token?(tokens, index)
        return false unless parameter_declaration_token?(tokens, index)

        opener_index = parameter_list_opener_index(tokens, index)
        return false unless opener_index

        head_index = previous_non_trivia_token_index(tokens, opener_index)
        return false unless head_index

        variant_enum_member_declaration?(tokens, head_index)
      end

      def parameter_declaration_token?(tokens, index)
        prev_tok = previous_non_trivia_token(tokens, index)
        next_tok = next_non_trivia_token(tokens, index + 1)
        next_tok&.type == :colon && prev_tok && [:lparen, :comma].include?(prev_tok.type)
      end

      def callable_parameter_declaration_token?(tokens, index)
        return false unless parameter_declaration_token?(tokens, index)

        opener_index = parameter_list_opener_index(tokens, index)
        return false unless opener_index

        head_index = previous_non_trivia_token_index(tokens, opener_index)
        return false unless head_index

        head = tokens[head_index]
        return true if [:fn, :proc].include?(head.type)

        if head.type == :rbracket
          lbracket_index = matching_opener_index(tokens, head_index)
          return false unless lbracket_index

          head_index = previous_non_trivia_token_index(tokens, lbracket_index)
          return false unless head_index

          head = tokens[head_index]
        end

        return false unless head.type == :identifier

        previous_non_trivia_token(tokens, head_index)&.type == :function
      end

      def parameter_list_opener_index(tokens, index)
        depth = 0
        i = index - 1
        while i >= 0
          tok = tokens[i]
          if tok.type == :rparen
            depth += 1
          elsif tok.type == :lparen
            return i if depth.zero?

            depth -= 1
          end
          i -= 1
        end

        nil
      end

      def lexically_declared_free_function_name?(tokens, name)
        lexically_declared_free_function_names(tokens).include?(name)
      end

      def lexically_declared_free_function_names(tokens)
        cache = @lexically_declared_free_function_name_cache ||= {}
        cached = cache[tokens.object_id]
        return cached if cached

        cache[tokens.object_id] = tokens.each_with_index.each_with_object(Set.new) do |(token, index), names|
          next unless token.type == :identifier

          prev_index = previous_non_trivia_token_index(tokens, index)
          next unless prev_index

          prev_tok = tokens[prev_index]
          next unless [:function, :fn, :proc].include?(prev_tok.type)
          next unless first_non_trivia_token_on_line?(tokens, prev_index)

          names << token.lexeme
        end
      end

      def generic_function_lexical_binding_semantic(facts, token)
        kind = generic_function_lexical_binding_kind_at(facts, token.line, token.column, token.lexeme)
        case kind
        when :param
          [:parameter, []]
        when :variable
          [:variable, []]
        else
          nil
        end
      end

      def generic_function_lexical_binding_kind_at(facts, line, column, name)
        generic_function_lexical_binding_scopes(facts).reverse_each do |scope|
          next if line < scope[:start_line] || line > scope[:end_line]
          next if line == scope[:start_line] && column < scope[:start_column]

          kind = scope[:bindings][name]
          return kind if kind
        end

        nil
      end

      def generic_function_lexical_binding_scopes(facts)
        scopes = @generic_function_lexical_binding_scope_cache ||= {}
        cached = scopes[facts.object_id]
        unless cached
          decls = Array(facts.ast&.declarations)
          cached = decls.each_with_index.flat_map do |decl, index|
            generic_function_lexical_scopes_for_declaration(
              decl,
              end_line: declaration_scope_end_line(decls, index),
            )
          end
          scopes[facts.object_id] = cached
        end

        cached
      end

      def generic_function_lexical_scopes_for_declaration(decl, end_line: Float::INFINITY)
        if decl.is_a?(AST::ExtendingBlock)
          receiver_type_params = generic_type_parameter_names_for_extending_block(decl)
          methods = Array(decl.methods)
          return methods.each_with_index.flat_map do |method, index|
            generic_method_lexical_scopes(
              method,
              receiver_type_params: receiver_type_params,
              end_line: nested_declaration_scope_end_line(methods, index, fallback_end_line: end_line),
            )
          end
        end

        return [] unless generic_function_declaration?(decl)

        generic_callable_lexical_scopes(decl, end_line: generic_statement_list_end_line(decl.body, decl.line))
      end

      def generic_method_lexical_scopes(method, receiver_type_params:, end_line:)
        return [] unless method.respond_to?(:body) && !method.body.nil?
        return [] if receiver_type_params.empty? && Array(method.type_params).empty?

        generic_callable_lexical_scopes(
          method,
          end_line:,
          include_receiver: method.respond_to?(:kind) && method.kind != :static,
        )
      end

      def generic_callable_lexical_scopes(decl, end_line:, include_receiver: false)
        scopes = []
        current_bindings = {}
        current_bindings['this'] = :param if include_receiver
        Array(decl.params).each do |param|
          next unless param.respond_to?(:name)

          current_bindings[param.name] = :param
        end

        unless current_bindings.empty?
          scopes << {
            start_line: decl.line,
            start_column: 0,
            end_line: end_line,
            bindings: current_bindings.dup,
          }
        end

        collect_generic_function_local_scopes(Array(decl.body), current_bindings, end_line, scopes)

        scopes
      end

      def generic_function_declaration?(decl)
        decl.respond_to?(:type_params) &&
          Array(decl.type_params).any? &&
          decl.respond_to?(:params) &&
          decl.respond_to?(:body) &&
          !decl.body.nil?
      end

      def collect_generic_function_local_scopes(statements, current_bindings, block_end_line, scopes)
        active_bindings = current_bindings.dup
        Array(statements).each do |statement|
          case statement
          when AST::LocalDecl
            active_bindings[statement.name] = :variable
            scopes << generic_binding_scope(statement, active_bindings, block_end_line)
          when AST::IfStmt
            Array(statement.branches).each do |branch|
              branch_body = Array(branch.body)
              branch_end_line = generic_statement_list_end_line(branch_body, statement.line)
              collect_generic_function_local_scopes(branch_body, active_bindings, branch_end_line, scopes)
            end

            else_body = Array(statement.else_body)
            unless else_body.empty?
              else_end_line = generic_statement_list_end_line(else_body, statement.line)
              collect_generic_function_local_scopes(else_body, active_bindings, else_end_line, scopes)
            end
          when AST::MatchStmt
            Array(statement.arms).each do |arm|
              arm_bindings = active_bindings.dup
              arm_body = Array(arm.body)
              arm_end_line = generic_statement_list_end_line(arm_body, statement.line)
              if arm.respond_to?(:binding_name) && arm.binding_name
                arm_bindings[arm.binding_name] = :variable
                scopes << generic_binding_scope(arm, arm_bindings, arm_end_line)
              end
              collect_generic_function_local_scopes(arm_body, arm_bindings, arm_end_line, scopes)
            end
          when AST::UnsafeStmt, AST::WhileStmt, AST::DeferStmt
            body = Array(statement.body)
            body_end_line = generic_statement_list_end_line(body, statement.line)
            collect_generic_function_local_scopes(body, active_bindings, body_end_line, scopes)
          when AST::ForStmt
            next unless statement.respond_to?(:name) && statement.name

            body = Array(statement.body)
            body_end_line = generic_statement_list_end_line(body, statement.line)
            for_bindings = active_bindings.dup
            for_bindings[statement.name] = :variable
            scopes << generic_binding_scope(statement, for_bindings, body_end_line)
            collect_generic_function_local_scopes(body, for_bindings, body_end_line, scopes)
          end
        end
      end

      def generic_binding_scope(node, bindings, end_line)
        {
          start_line: node.respond_to?(:line) && node.line ? node.line : 0,
          start_column: node.respond_to?(:column) && node.column ? node.column : 0,
          end_line: end_line,
          bindings: bindings.dup,
        }
      end

      def generic_statement_list_end_line(statements, fallback_line)
        Array(statements).reduce(fallback_line || 0) do |max_line, statement|
          [max_line, generic_statement_end_line(statement)].compact.max
        end
      end

      def generic_statement_end_line(statement)
        return 0 unless statement

        case statement
        when AST::IfStmt
          branch_lines = Array(statement.branches).map do |branch|
            generic_statement_list_end_line(Array(branch.body), branch.respond_to?(:line) ? branch.line : statement.line)
          end
          else_line = generic_statement_list_end_line(Array(statement.else_body), statement.line)
          ([statement.line, else_line] + branch_lines).compact.max
        when AST::MatchStmt
          arm_lines = Array(statement.arms).map do |arm|
            generic_statement_list_end_line(Array(arm.body), arm.respond_to?(:line) ? arm.line : statement.line)
          end
          ([statement.line] + arm_lines).compact.max
        when AST::UnsafeStmt, AST::WhileStmt, AST::ForStmt, AST::DeferStmt
          [statement.line, generic_statement_list_end_line(Array(statement.body), statement.line)].compact.max
        else
          statement.respond_to?(:line) ? statement.line : 0
        end
      end

      def namespace_keyword_token?(tokens, index)
        tok = tokens[index]
        return false unless tok && Token::KEYWORDS.value?(tok.type)

        import_path_info_at(tokens, index, allow_keywords: true) ||
          module_declaration_path_token?(tokens, index, allow_keywords: true)

      end

      def local_semantic_value_binding(facts, token, allow_same_line_future: false)
        char = token.column - 1
        [token.line - 1, token.line].uniq.each do |line|
          frame = enclosing_completion_frame(facts, line)
          next unless frame

          snapshot = latest_completion_snapshot(frame, line, char)
          binding = snapshot&.bindings&.dig(token.lexeme)
          return binding if binding

          next unless allow_same_line_future

          future_snapshot = same_line_future_completion_snapshot(frame, line, char)
          binding = future_snapshot&.bindings&.dig(token.lexeme)
          return binding if binding
        end

        nil
      end

      def semantic_value_binding_entry(binding, declaration: false)
        case binding.kind
        when :param
          modifiers = []
          modifiers << 'declaration' if declaration
          [:parameter, modifiers]
        when :const
          [:variable, ['readonly']]
        else
          modifiers = []
          modifiers << 'declaration' if declaration
          [:variable, modifiers]
        end
      end

      def resolved_call_callee_semantic(name, token, parameter_declaration, facts)
        if (binding = local_semantic_value_binding(facts, token, allow_same_line_future: parameter_declaration))
          return semantic_value_binding_entry(binding, declaration: binding.kind == :param && parameter_declaration)
        end

        if (binding = facts.values[name])
          return semantic_value_binding_entry(binding)
        end

        modifiers = []
        modifiers << 'defaultLibrary' if BUILTIN_FUNCTION_NAMES.include?(name)
        return [:function, modifiers] if BUILTIN_FUNCTION_NAMES.include?(name)
        return [:function, modifiers] if facts.functions.key?(name)
        return [:type, []] if constructible_semantic_type?(facts.types[name])

        nil
      end

      def callable_field_member_access?(name, tokens, index, facts)
        next_tok = next_non_trivia_token(tokens, index + 1)
        return false unless next_tok&.type == :lparen

        dot_index = previous_non_trivia_token_index(tokens, index)
        return false unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return false unless receiver_index

        receiver_tok = tokens[receiver_index]
        return false unless receiver_tok.type == :identifier

        resolve_receiver_value_type(facts, receiver_tok).then do |receiver_type|
          next false unless receiver_type

          field_receiver_type = project_field_receiver_type_for_completion(receiver_type)
          next false unless field_receiver_type.respond_to?(:field)

          callable_semantic_type?(field_receiver_type.field(name))
        end
      end

      def resolve_receiver_value_type(facts, token)
        char = token.column

        [token.line - 1, token.line].uniq.each do |line|
          receiver_type = resolve_dot_receiver_value_type(facts, token.lexeme, line, char)
          return receiver_type if receiver_type
        end

        nil
      end

      def callable_semantic_type?(type)
        type.is_a?(Types::Function) || type.is_a?(Types::Proc)
      end

      def constructible_semantic_type?(type)
        type.is_a?(Types::Struct) || type.is_a?(Types::StringView) || type.is_a?(Types::Task)
      end

      def bare_builtin_specialization?(name, tokens, index)
        return false unless name == 'zero' || name == 'default'

        next_index = next_non_trivia_token_index(tokens, index + 1)
        return false unless next_index && tokens[next_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, next_index, :lbracket, :rbracket)
        return false unless rbracket_index

        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)
        after_bracket_index.nil? || tokens[after_bracket_index].type != :lparen
      end

      def bare_function_value_identifier_site?(facts, token)
        facts.functions.key?(token.lexeme) &&
          facts.callable_value_identifier_sites.fetch([token.line, token.column], false)
      end

      def imported_module_function_value_member_access_site?(facts, tokens, index)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return false unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return false unless receiver_index

        receiver = tokens[receiver_index]
        return false unless receiver.type == :identifier

        facts.callable_value_member_access_sites.fetch(
          [receiver.lexeme, receiver.line, receiver.column, tokens[index].lexeme],
          false,
        )
      end

      def imported_module_binding_for_member(tokens, index, facts)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return nil unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return nil unless receiver_index

        receiver = tokens[receiver_index]
        return nil unless receiver.type == :identifier

        facts.imports[receiver.lexeme]
      end

      def static_type_member_access?(tokens, index, facts)
        receiver_info = dot_type_receiver_info(tokens, index, facts)
        return false unless receiver_info

        !static_method_binding_for_receiver(facts, receiver_info[:type], tokens[index].lexeme).nil?
      end

      def dot_type_receiver_info(tokens, index, facts)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return nil unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return nil unless receiver_index

        if tokens[receiver_index].type == :rbracket
          lbracket_index = matching_opener_index(tokens, receiver_index)
          return nil unless lbracket_index

          receiver_index = previous_non_trivia_token_index(tokens, lbracket_index)
          return nil unless receiver_index
        end

        receiver = tokens[receiver_index]
        return nil unless receiver.type == :identifier

        receiver_name = receiver.lexeme
        receiver_path = receiver_name

        module_dot_index = previous_non_trivia_token_index(tokens, receiver_index)
        if module_dot_index && tokens[module_dot_index].type == :dot
          module_index = previous_non_trivia_token_index(tokens, module_dot_index)
          return nil unless module_index && tokens[module_index].type == :identifier

          receiver_path = "#{tokens[module_index].lexeme}.#{receiver_name}"
        end

        resolve_type_receiver_info(facts, receiver_name, receiver_path)
      end

      def specialized_call_with_type_args?(tokens, index)
        next_index = next_non_trivia_token_index(tokens, index + 1)
        return false unless next_index && tokens[next_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, next_index, :lbracket, :rbracket)
        return false unless rbracket_index

        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)
        after_bracket_index && tokens[after_bracket_index].type == :lparen
      end

      def identifier_in_type_argument_position?(tokens, index)
        lbracket_index = previous_non_trivia_token_index(tokens, index)
        return false unless lbracket_index

        if tokens[lbracket_index].type == :comma
          depth = 0
          i = lbracket_index - 1
          lbracket_index = nil
          while i >= 0
            tok = tokens[i]
            if tok.type == :rbracket
              depth += 1
            elsif tok.type == :lbracket
              if depth.zero?
                lbracket_index = i
                break
              end

              depth -= 1
            end
            i -= 1
          end
        end

        return false unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return false unless rbracket_index

        next_index = next_non_trivia_token_index(tokens, index + 1)
        return false unless next_index

        # Type argument entries should stay inside the current [] pair.
        next_index <= rbracket_index
      end

      def type_parameter_declaration_token?(facts, tokens, index)
        info = type_parameter_declaration_info_on_line(tokens, tokens[index].line)
        info && info[:tokens].any? { |token| token.equal?(tokens[index]) }
      end

      def type_parameter_reference_token?(facts, tokens, index)
        tok = tokens[index]
        names = type_parameter_names_in_scope(facts, tok.line)
        return false unless names.include?(tok.lexeme) || names.include?("@#{tok.lexeme}")
        return false if type_parameter_declaration_token?(facts, tokens, index)

        identifier_in_type_parameter_reference_position?(tokens, index)
      end

      def identifier_in_type_parameter_reference_position?(tokens, index)
        return true if identifier_in_type_argument_position?(tokens, index)

        prev_tok = previous_non_trivia_token(tokens, index)
        [:colon, :arrow].include?(prev_tok&.type)
      end

      def identifier_in_type_reference_position?(tokens, index)
        return true if identifier_in_type_argument_position?(tokens, index)

        prev_tok = previous_non_trivia_token(tokens, index)
        return true if [:colon, :arrow, :as].include?(prev_tok&.type)

        line_tokens = non_trivia_tokens_on_line(tokens, tokens[index].line)
        return true if prev_tok&.type == :equal && line_tokens.first&.type == :type

        next_index = next_non_trivia_token_index(tokens, index + 1)
        return false unless next_index && tokens[next_index].type == :less

        minus_index = next_non_trivia_token_index(tokens, next_index + 1)
        return false unless minus_index && tokens[minus_index].type == :minus

        tokens[next_index].line == tokens[index].line &&
          tokens[next_index].column == (tokens[index].column + tokens[index].lexeme.length) &&
          tokens[minus_index].line == tokens[next_index].line &&
          tokens[minus_index].column == (tokens[next_index].column + tokens[next_index].lexeme.length)
      end

      def type_parameter_declaration_info_on_line(tokens, line)
        line_tokens = non_trivia_tokens_on_line(tokens, line)
        return nil if line_tokens.empty?

        header_index = line_tokens.index { |line_tok| generic_type_parameter_header_token?(line_tok.type) }
        return nil unless header_index

        name_index = ((header_index + 1)...line_tokens.length).find { |i| line_tokens[i].type == :identifier }
        return nil unless name_index

        lbracket_index = name_index + 1
        return nil unless line_tokens[lbracket_index]&.type == :lbracket

        depth = 0
        type_param_tokens = []
        expect_name = false
        i = lbracket_index
        while i < line_tokens.length
          tok = line_tokens[i]
          case tok.type
          when :lbracket
            depth += 1
            expect_name = true if depth == 1
          when :rbracket
            depth -= 1
            return {
              names: type_param_tokens.map(&:lexeme),
              tokens: type_param_tokens,
            } if depth.zero?
          when :comma
            expect_name = true if depth == 1
          when :implements
            expect_name = false if depth == 1
          else
            if depth == 1 && expect_name && tok.type == :identifier
              type_param_tokens << tok
              expect_name = false
            end
          end
          i += 1
        end

        nil
      end

      def generic_type_parameter_header_token?(type)
        [:function, :struct, :union, :enum, :flags, :variant, :type, :extending].include?(type)
      end

      def type_parameter_names_in_scope(facts, line)
        scopes = @type_parameter_scope_cache ||= {}
        cached = scopes[facts.object_id]
        unless cached
          decls = Array(facts.ast&.declarations)
          cached = decls.each_with_index.flat_map do |decl, index|
            type_parameter_scopes_for_declaration(
              decl,
              end_line: declaration_scope_end_line(decls, index),
            )
          end
          scopes[facts.object_id] = cached
        end

        cached.reverse_each do |scope|
          return scope[:names] if line >= scope[:start_line] && line <= scope[:end_line]
        end

        []
      end

      def type_parameter_scopes_for_declaration(decl, end_line: Float::INFINITY)
        if decl.is_a?(AST::ExtendingBlock)
          receiver_names = generic_type_parameter_names_for_extending_block(decl)
          methods = Array(decl.methods)
          return methods.each_with_index.filter_map do |method, index|
            names = receiver_names + generic_type_parameter_names_for_declaration(method)
            next if names.empty? || method.line.nil?

            {
              start_line: method.line,
              end_line: nested_declaration_scope_end_line(methods, index, fallback_end_line: end_line),
              names: names.uniq,
            }
          end
        end

        names = generic_type_parameter_names_for_declaration(decl)
        return [] if names.empty? || decl.line.nil?

        [{
          start_line: decl.line,
          end_line: end_line,
          names: names,
        }]
      end

      def generic_type_parameter_names_for_declaration(decl)
        return [] unless decl.respond_to?(:type_params)

        Array(decl.type_params).filter_map { |type_param| type_param.respond_to?(:name) ? type_param.name : nil }
      end

      def generic_type_parameter_names_for_extending_block(decl)
        return [] unless decl.respond_to?(:type_name)

        type_ref = decl.type_name
        return [] unless type_ref.is_a?(AST::TypeRef)

        Array(type_ref.arguments).filter_map do |argument|
          simple_type_parameter_name_from_type_argument(argument)
        end
      end

      def simple_type_parameter_name_from_type_argument(argument)
        value = argument.respond_to?(:value) ? argument.value : nil
        return nil unless value.is_a?(AST::TypeRef)
        return nil unless value.arguments.empty? && !value.nullable && value.name.parts.length == 1

        value.name.parts.first
      end

      def declaration_scope_end_line(decls, index)
        nested_declaration_scope_end_line(decls, index, fallback_end_line: Float::INFINITY)
      end

      def nested_declaration_scope_end_line(decls, index, fallback_end_line:)
        next_decl = decls[(index + 1)..]&.find { |candidate| candidate.respond_to?(:line) && !candidate.line.nil? }
        next_decl ? next_decl.line - 1 : fallback_end_line
      end

      def matching_closer_index(tokens, opener_index, opener_type, closer_type)
        depth = 0
        i = opener_index
        while i < tokens.length
          tok = tokens[i]
          if tok.type == opener_type
            depth += 1
          elsif tok.type == closer_type
            depth -= 1
            return i if depth.zero?
          end
          i += 1
        end
        nil
      end

      def import_path_info_at(tokens, index, allow_keywords: false)
        tok = tokens[index]
        return nil unless tok
        return nil unless tok.type == :identifier || (allow_keywords && Token::KEYWORDS.value?(tok.type))

        line_tokens = non_trivia_tokens_on_line(tokens, tok.line)
        return nil if line_tokens.empty? || line_tokens.first.type != :import

        as_index = line_tokens.index { |line_tok| line_tok.type == :as }
        module_tokens = line_tokens[1...(as_index || line_tokens.length)] || []
        alias_token = as_index ? line_tokens[as_index + 1] : nil

        module_identifiers = module_tokens.select do |line_tok|
          line_tok.type == :identifier || (allow_keywords && Token::KEYWORDS.value?(line_tok.type))
        end
        return nil if module_identifiers.empty?

        module_name = module_identifiers.map(&:lexeme).join('.')
        return { module_name: module_name, role: :module_path } if module_identifiers.include?(tok)
        return { module_name: module_name, role: :alias } if alias_token == tok

        nil
      end

      def variant_enum_member_declaration?(tokens, index)
        tok = tokens[index]
        line_tokens = non_trivia_tokens_on_line(tokens, tok.line)
        return false unless line_tokens.first.equal?(tok) && tok.column > 1

        i = index - 1
        while i >= 0
          t = tokens[i]
          i -= 1
          next if [:newline, :indent, :dedent, :eof].include?(t.type)
          next if t.line == tok.line
          next if t.column >= tok.column

          header_line_toks = non_trivia_tokens_on_line(tokens, t.line)
          header_kind = header_line_toks.find { |header_tok| [:variant, :enum, :flags].include?(header_tok.type) }
          return !header_kind.nil?
        end
        false
      end

      def type_name_member_access?(tokens, index, facts = nil)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return false unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return false unless receiver_index

        type_name_receiver_token?(tokens, receiver_index, facts)
      end

      def type_name_receiver_token?(tokens, index, facts = nil)
        receiver = tokens[index]

        if receiver.type == :identifier
          return true if receiver.lexeme.match?(/\A[A-Z]/)
          return true if facts && facts.types.key?(receiver.lexeme)

          if facts
            module_binding = imported_module_binding_for_member(tokens, index, facts)
            return true if module_binding && module_binding.types.key?(receiver.lexeme)
          end

          return false
        end

        if receiver.type == :rbracket
          lbracket_i = matching_opener_index(tokens, index)
          return false unless lbracket_i

          base_index = previous_non_trivia_token_index(tokens, lbracket_i)
          return false unless base_index

          return type_name_receiver_token?(tokens, base_index, facts)
        end

        false
      end

      def matching_opener_index(tokens, closer_index)
        closer = tokens[closer_index]
        return nil unless closer

        opener_type, closer_type = case closer.type
          when :rbracket then [:lbracket, :rbracket]
          when :rparen   then [:lparen,   :rparen]
          else return nil
        end

        depth = 0
        i = closer_index
        while i >= 0
          t = tokens[i]
          if t.type == closer_type
            depth += 1
          elsif t.type == opener_type
            depth -= 1
            return i if depth.zero?
          end
          i -= 1
        end
        nil
      end

      def non_trivia_tokens_on_line(tokens, line)
        return @tokens_by_line_cache[line] if @tokens_by_line_cache

        tokens.select do |tok|
          tok.line == line && ![:newline, :indent, :dedent, :eof].include?(tok.type)
        end
      end

      def build_attribute_name_semantic_overrides(tokens, facts)
        return {} unless facts&.respond_to?(:ast) && facts.ast

        token_indices_by_position = tokens.each_with_index.each_with_object({}) do |(token, index), positions|
          positions[[token.line, token.column]] = index
        end
        overrides = {}

        walk_ast_nodes(facts.ast) do |node|
          case node
          when AST::AttributeDecl
            mark_attribute_name_override(
              overrides,
              token_indices_by_position,
              tokens,
              [node.name],
              line: node.line,
              column: node.column,
              declaration: true,
            )
          when AST::AttributeApplication
            mark_attribute_name_override(
              overrides,
              token_indices_by_position,
              tokens,
              node.name.parts,
              line: node.line,
              column: node.column,
            )
          when AST::Call
            mark_attribute_reflection_name_overrides(overrides, token_indices_by_position, tokens, node)
          end
        end

        overrides
      end

      def walk_ast_nodes(node, &block)
        case node
        when Array
          node.each { |entry| walk_ast_nodes(entry, &block) }
        when String, Symbol, Numeric, TrueClass, FalseClass, NilClass
          nil
        else
          return unless node.class.name&.start_with?("MilkTea::AST::")

          yield node
          node.to_h.each_value { |value| walk_ast_nodes(value, &block) }
        end
      end

      def mark_attribute_reflection_name_overrides(overrides, token_indices_by_position, tokens, call_expression)
        callee = call_expression.callee
        return unless callee.is_a?(AST::Identifier)
        return unless %w[has_attribute attribute_of].include?(callee.name)
        return unless call_expression.arguments.length >= 2

        attribute_name_expression = call_expression.arguments[1].value

        case attribute_name_expression
        when AST::Identifier
          mark_attribute_name_override(
            overrides,
            token_indices_by_position,
            tokens,
            [attribute_name_expression.name],
            line: attribute_name_expression.line,
            column: attribute_name_expression.column,
          )
        when AST::MemberAccess
          return unless attribute_name_expression.receiver.is_a?(AST::Identifier)

          mark_attribute_name_override(
            overrides,
            token_indices_by_position,
            tokens,
            [attribute_name_expression.receiver.name, attribute_name_expression.member],
            line: attribute_name_expression.receiver.line,
            column: attribute_name_expression.receiver.column,
          )
        end
      end

      def mark_attribute_name_override(overrides, token_indices_by_position, tokens, parts, line:, column:, declaration: false)
        current_index = token_indices_by_position[[line, column]]
        return unless current_index

        parts.each_with_index do |part, part_index|
          token = tokens[current_index]
          return unless token&.lexeme == part

          if part_index == parts.length - 1
            modifiers = []
            modifiers << 'declaration' if declaration
            overrides[[token.line, token.column]] = [:decorator, modifiers]
            return
          end

          overrides[[token.line, token.column]] = [:namespace, []]
          dot_index = next_non_trivia_token_index(tokens, current_index + 1)
          return unless dot_index && tokens[dot_index].type == :dot

          current_index = next_non_trivia_token_index(tokens, dot_index + 1)
          return unless current_index
        end
      end

      def module_declaration_path_token?(tokens, index, allow_keywords: false)
        !module_declaration_info_at(tokens, index, allow_keywords:).nil?
      end

      def module_declaration_info_at(tokens, index, allow_keywords: false)
        tok = tokens[index]
        return nil unless tok&.type == :identifier || (allow_keywords && Token::KEYWORDS.value?(tok.type))

        line_tokens = non_trivia_tokens_on_line(tokens, tok.line)
        return nil if line_tokens.empty? || line_tokens.first.type != :module

        path_tokens = line_tokens[1..].to_a.select do |line_tok|
          line_tok.type == :identifier || (allow_keywords && Token::KEYWORDS.value?(line_tok.type))
        end
        return nil unless path_tokens.any? { |line_tok| line_tok.equal?(tok) }

        {
          module_name: path_tokens.map(&:lexeme).join('.'),
        }
      end

      def previous_non_trivia_token(tokens, index)
        prev_index = previous_non_trivia_token_index(tokens, index)
        return nil unless prev_index

        tokens[prev_index]
      end

      def first_non_trivia_token_on_line?(tokens, index)
        token = tokens[index]
        return false unless token

        i = index - 1
        while i >= 0
          previous = tokens[i]
          return true if previous.type == :newline
          return false if previous.line == token.line && ![:indent, :dedent].include?(previous.type)

          i -= 1
        end

        true
      end

      def previous_non_trivia_token_index(tokens, index)
        i = index - 1
        while i >= 0
          tok = tokens[i]
          return i unless [:newline, :indent, :dedent].include?(tok.type)
          i -= 1
        end
        nil
      end

      def next_non_trivia_token_index(tokens, index)
        i = index
        while i < tokens.length
          tok = tokens[i]
          return i unless [:newline, :indent, :dedent].include?(tok.type)
          i += 1
        end
        nil
      end

      def encode_semantic_tokens(entries)
        data = []
        prev_line = 0
        prev_char = 0

        entries.each do |entry|
          delta_line = entry[:line] - prev_line
          delta_start = delta_line.zero? ? entry[:start_char] - prev_char : entry[:start_char]
          type_index = SEMANTIC_TOKEN_TYPES.index(entry[:type].to_s) || 0
          modifiers_bitset = semantic_modifiers_bitset(entry[:modifiers])

          data << delta_line
          data << delta_start
          data << entry[:length]
          data << type_index
          data << modifiers_bitset

          prev_line = entry[:line]
          prev_char = entry[:start_char]
        end

        data
      end

      def next_semantic_token_result_id(uri)
        @semantic_token_result_counter ||= 0
        @semantic_token_result_counter += 1
        "#{uri}:#{@semantic_token_result_counter}"
      end

      def compute_semantic_tokens_edits(old_entries, new_entries)
        return [] if old_entries == new_entries

        prefix = find_semantic_token_common_prefix(old_entries, new_entries)
        suffix = find_semantic_token_common_suffix(old_entries, new_entries, prefix)

        old_mid = old_entries.length - prefix - suffix
        new_mid = new_entries.length - prefix - suffix

        if old_mid.zero? && new_mid.zero?
          return []
        end

        start_offset = prefix * 5
        delete_count = old_mid * 5
        insert_tokens = encode_semantic_tokens(new_entries[prefix...(new_entries.length - suffix)])

        [{ start: start_offset, deleteCount: delete_count, data: insert_tokens }]
      end

      def find_semantic_token_common_prefix(old_entries, new_entries)
        limit = [old_entries.length, new_entries.length].min
        prefix = 0
        while prefix < limit && semantic_token_entry_equal?(old_entries[prefix], new_entries[prefix])
          prefix += 1
        end
        prefix
      end

      def find_semantic_token_common_suffix(old_entries, new_entries, prefix)
        old_limit = old_entries.length - prefix
        new_limit = new_entries.length - prefix
        limit = [old_limit, new_limit].min
        suffix = 0
        while suffix < limit &&
              semantic_token_entry_equal?(old_entries[old_entries.length - 1 - suffix],
                                          new_entries[new_entries.length - 1 - suffix])
          suffix += 1
        end
        suffix
      end

      def semantic_token_entry_equal?(a, b)
        a[:line] == b[:line] &&
          a[:start_char] == b[:start_char] &&
          a[:length] == b[:length] &&
          a[:type] == b[:type] &&
          a[:modifiers] == b[:modifiers]
      end

      def semantic_modifiers_bitset(modifiers)
        bits = 0
        Array(modifiers).each do |modifier|
          idx = SEMANTIC_TOKEN_MODIFIERS.index(modifier.to_s)
          next unless idx

          bits |= (1 << idx)
        end
        bits
      end

      def generic_function_binding_for_line(facts, line)
        generic_function_bindings(facts).filter_map do |binding|
          next unless binding.ast.respond_to?(:body) && binding.ast.respond_to?(:line)

          start_line = binding.ast.line
          end_line = generic_statement_list_end_line(Array(binding.ast.body), start_line)
          next unless start_line <= line && line <= end_line

          [end_line - start_line, -start_line, binding]
        end.min_by { |span, start_line, _binding| [span, start_line] }&.last
      end

      def generic_function_bindings(facts)
        facts.functions.each_value.select { |binding| binding.type_params.any? } +
          facts.methods.each_value.flat_map(&:values).select { |binding| binding.type_params.any? }
      end
      end
    end
  end
end
