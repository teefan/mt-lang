# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerCompletion
        MAX_COMPLETION_ITEMS = 200

        COMPLETION_KEYWORDS = %w[
          let var const function async struct enum flags variant union
          type interface opaque if while for match return import public static
          extending external fn event attribute defer break continue pass
          unsafe consuming implements include link foreign proc
          editable in out inout as when inline await static_assert emit
        ].freeze

        TYPE_CONSTRUCTOR_KEYWORDS = %w[
          ptr ref span array dyn Option Result Task SoA str_buffer const_ptr
        ].freeze

        private

        def completion_data(name)
          { uri: @current_completion_uri || '', name: }
        end

        def snippet_for_callable(label, params)
          return "#{label}()" if params.empty?
          return nil if params.length > 5

          stops = params.each_with_index.map { |p, i| "${#{i + 1}:#{p.name}}" }
          "#{label}(#{stops.join(', ')})"
        end

      def handle_completion(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        @current_completion_uri = uri
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        branch = 'none'
        item_count = 0

        prefix = measure_perf_stage(stages, 'prefix') { current_word_prefix(uri, lsp_line, lsp_char) }

        import_items = measure_perf_stage(stages, 'import_context') { import_completions(uri, lsp_line, lsp_char) }
        if import_items
          branch = 'import'
          item_count = import_items.length
          return { isIncomplete: false, items: import_items }
        end

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }

        unless facts
          branch = 'no-facts'
          return { isIncomplete: false, items: [] }
        end

        # Attribute context: complete inside @[...]
        attr_items = attribute_completions(facts, uri, lsp_line, lsp_char)
        if attr_items
          branch = 'attribute'
          item_count = attr_items.length
          return { isIncomplete: false, items: attr_items }
        end

        # Format string interpolation: complete inside f"... #{ }
        fmt_items = format_string_completions(facts, uri, lsp_line, lsp_char)
        if fmt_items
          branch = 'format-string'
          item_count = fmt_items.length
          return { isIncomplete: false, items: fmt_items }
        end

        # Named argument completions: inside function/struct call e.g. Point(x: 1, |)
        named_items = named_argument_completions(facts, uri, lsp_line, lsp_char)
        if named_items
          branch = 'named-arg'
          item_count = named_items.length
          return { isIncomplete: false, items: named_items }
        end

        # Specialization context: inside name[...]
        spec_items = specialization_completions(facts, uri, lsp_line, lsp_char)
        if spec_items
          branch = 'specialization'
          item_count = spec_items.length
          return { isIncomplete: false, items: spec_items }
        end

        # When user is typing after '.', return module members or method completions.
        dot_recv = nil
        dot_recv_path = nil
        measure_perf_stage(stages, 'receiver_context') do
          dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          dot_recv_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
        end
        if dot_recv
          # Module member access: rl.init_window, rl.RAYWHITE, etc.
          if (module_binding = facts.imports[dot_recv])
            branch = 'module'
            items = measure_perf_stage(stages, 'build') do
              result = []
              module_binding.functions.each do |fname, binding|
                next unless prefix.empty? || fname.start_with?(prefix)
                params_str = format_params(binding.type.params)
                item = {
                  label:      fname,
                  kind:       12, # Function
                  detail:     "function #{fname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: fname,
                  sortText:   "0_#{fname}",
                  data:       completion_data(fname),
                }
                if (snippet = snippet_for_callable(fname, binding.type.params))
                  item[:insertText] = snippet
                  item[:insertTextFormat] = 2
                end
                result << item
              end
              module_binding.values.each do |vname, binding|
                next unless prefix.empty? || vname.start_with?(prefix)
                result << {
                  label:      vname,
                  kind:       13, # Variable
                  detail:     "#{vname}: #{binding.type}",
                  insertText: vname,
                  sortText:   "1_#{vname}",
                  data:       completion_data(vname),
                }
              end
              module_binding.types.each do |tname, _type|
                next unless prefix.empty? || tname.start_with?(prefix)
                result << {
                  label:      tname,
                  kind:       5,  # Class
                  detail:     "type #{tname}",
                  insertText: tname,
                  sortText:   "2_#{tname}",
                  data:       completion_data(tname),
                }
              end
              result
            end
            item_count = items.length
            return { isIncomplete: false, items: items }
          end
          if (type_receiver = measure_perf_stage(stages, 'type_receiver') { resolve_type_receiver_info(facts, dot_recv, dot_recv_path) })
            receiver_label = type_receiver[:label]
            type = type_receiver[:type]


            # Enum/Flags member access: Color.RED, KeyboardKey.A, etc.
            if type.is_a?(Types::EnumBase)
              branch = 'enum-members'
              items = measure_perf_stage(stages, 'build') do
                type.members.filter_map do |mname|
                  next if !prefix.empty? && !mname.start_with?(prefix)
                  {
                    label:      mname,
                    kind:       22, # EnumMember
                    detail:     "#{receiver_label}.#{mname}",
                    insertText: mname,
                    sortText:   "0_#{mname}",
                    data:       completion_data(mname),
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items }
            end

            # Variant arm access: Option.none, Result.success, etc.
            if type.is_a?(Types::Variant)
              branch = 'variant-arms'
              items = measure_perf_stage(stages, 'build') do
                type.arm_names.filter_map do |aname|
                  next if !prefix.empty? && !aname.start_with?(prefix)
                  {
                    label:      aname,
                    kind:       22, # EnumMember
                    detail:     "#{receiver_label}.#{aname}",
                    insertText: aname,
                    sortText:   "0_#{aname}",
                    data:       completion_data(aname),
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items }
            end

            # Nested struct type members: ShapeGroup.CircleData, etc.
            if type.is_a?(Types::Struct) && type.respond_to?(:nested_types) && type.nested_types.any?
              branch = 'nested-types'
              items = measure_perf_stage(stages, 'build') do
                type.nested_types.filter_map do |nt_name, _nt_type|
                  next if !prefix.empty? && !nt_name.start_with?(prefix)
                  {
                    label:      nt_name,
                    kind:       5,  # Class/type
                    detail:     "#{receiver_label}.#{nt_name}",
                    insertText: nt_name,
                    sortText:   "1_#{nt_name}",
                    data:       completion_data(nt_name),
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items } unless items.empty?
            end

            items = measure_perf_stage(stages, 'build') { completion_items_for_type_receiver(facts, type, prefix) }
            unless items.empty?
              branch = 'type-receiver'
              item_count = items.length
              return { isIncomplete: false, items: items }
            end
          end

          if dot_recv_path && dot_recv_path.include?('.')
            segments = dot_recv_path.split('.', 2)
            mod_alias = segments.first
            value_name = segments[1]
            if mod_alias && value_name && (mod_binding = facts.imports[mod_alias])
              if (val_binding = mod_binding.values[value_name])
                receiver_type = measure_perf_stage(stages, 'imported_value_receiver') { val_binding.type }
                items = measure_perf_stage(stages, 'build') { completion_items_for_value_receiver(facts, receiver_type, prefix) }
                unless items.empty?
                  branch = 'imported-value-receiver'
                  item_count = items.length
                  return { isIncomplete: false, items: items }
                end
              end
            else
              chain_items = measure_perf_stage(stages, 'value_chain') { value_chain_completions(facts, dot_recv_path, lsp_line, lsp_char, prefix) }
              if chain_items
                branch = 'value-chain'
                item_count = chain_items.length
                return { isIncomplete: false, items: chain_items }
              end
            end
          end

          if (receiver_type = measure_perf_stage(stages, 'value_receiver') { resolve_dot_receiver_value_type(facts, dot_recv, lsp_line + 1, lsp_char + 1) })
            items = measure_perf_stage(stages, 'build') { completion_items_for_value_receiver(facts, receiver_type, prefix) }
            unless items.empty?
              branch = 'value-receiver'
              item_count = items.length
              return { isIncomplete: false, items: items }
            end
          end

          # Method completions on a non-module receiver.
          branch = 'method-fallback'
          method_items = measure_perf_stage(stages, 'build') do
            result = []
            facts.methods.each do |_recv_type, methods|
              methods.each do |mname, binding|
                next unless prefix.empty? || mname.start_with?(prefix)

                params_str = format_params(binding.type.params)
                item = {
                  label:      mname,
                  kind:       6,  # Method
                  detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: mname,
                  sortText:   "0_#{mname}",
                  data:       completion_data(mname),
                }
                if (snippet = snippet_for_callable(mname, binding.type.params))
                  item[:insertText] = snippet
                  item[:insertTextFormat] = 2
                end
                result << item
              end
            end
            result
          end
          item_count = method_items.length
          truncated = item_count > MAX_COMPLETION_ITEMS
          if truncated
            method_items = method_items.first(MAX_COMPLETION_ITEMS)
            item_count = MAX_COMPLETION_ITEMS
          end
          return { isIncomplete: truncated, items: method_items }
        end

        branch = 'global'
        items = measure_perf_stage(stages, 'build') do
          result = []
          function_docs_cache = {}

          # Functions
          facts.functions.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            params_str = format_params(binding.type.params)
            entry = {
              label:        name,
              kind:         12, # Function
              detail:       "function #{name}(#{params_str}) -> #{binding.type.return_type}",
              insertText:   name,
              sortText:     "0_#{name}",
              data:         completion_data(name),
            }

            if (snippet = snippet_for_callable(name, binding.type.params))
              entry[:insertText] = snippet
              entry[:insertTextFormat] = 2
            end

            docs = completion_function_documentation(uri, name, cache: function_docs_cache)
            unless docs.empty?
              entry[:documentation] = {
                kind: 'markdown',
                value: docs,
              }
            end

            result << entry
          end

          # Types
          builtin_names = SemanticAnalyzer::INSTALLABLE_BUILTIN_TYPE_NAMES
          facts.types.each do |name, type|
            next if builtin_names.include?(name)
            next unless prefix.empty? || name.start_with?(prefix)

            kind = case type
                   when Types::StructInstance then 22 # Struct
                   when Types::EnumBase, Types::Variant then 13 # Enum
                   else 7 # Class/type
                   end

            result << {
              label:        name,
              kind:         kind,
              detail:       "type #{name}",
              insertText:   name,
              sortText:     "1_#{name}",
              data:         completion_data(name),
            }
          end

          # Imported modules
          facts.imports.each do |name, module_binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         2,  # Module
              detail:       "module #{module_binding.name}",
              insertText:   name,
              sortText:     "2_#{name}",
              data:         completion_data(name),
            }
          end

          # Values
          facts.values.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         13, # Variable
              detail:       "#{name}: #{binding.type}",
              insertText:   name,
              sortText:     "3_#{name}",
              data:         completion_data(name),
            }
          end

          # Locals (variables and parameters visible in current scope)
          frame = enclosing_completion_frame(facts, lsp_line + 1)
          if frame
            snapshot = latest_completion_snapshot(frame, lsp_line + 1, lsp_char + 1)
            if snapshot
              snapshot.bindings.each do |name, binding|
                next unless prefix.empty? || name.start_with?(prefix)
                next unless binding.respond_to?(:name) && binding.respond_to?(:type)

                detail_label = case binding.respond_to?(:kind) && binding.kind
                               when :param then "parameter #{name}: #{binding.type}"
                               when :local then "local #{name}: #{binding.type}"
                               else "#{name}: #{binding.type}"
                               end

                result << {
                  label:        name,
                  kind:         13, # Variable
                  detail:       detail_label,
                  insertText:   name,
                  sortText:     "3_#{name}",
                  data:         completion_data(name),
                }
              end
            end
          end

          TYPE_CONSTRUCTOR_KEYWORDS.each do |tc|
            next unless prefix.empty? || tc.start_with?(prefix)

            result << {
              label:      tc,
              kind:       14, # Keyword
              detail:     "type constructor #{tc}",
              insertText: tc,
              sortText:   "8_#{tc}",
              data:       completion_data(tc),
            }
          end

          COMPLETION_KEYWORDS.each do |kw|
            next unless prefix.empty? || kw.start_with?(prefix)

            result << {
              label:      kw,
              kind:       14, # Keyword
              detail:     "keyword #{kw}",
              insertText: kw,
              sortText:   "9_#{kw}",
              data:       completion_data(kw),
            }
          end

          result
        end

        item_count = items.length
        truncated = item_count > MAX_COMPLETION_ITEMS
        if truncated
          items = items.first(MAX_COMPLETION_ITEMS)
          item_count = MAX_COMPLETION_ITEMS
        end
        { isIncomplete: truncated, items: items }
      rescue StandardError => e
        branch = 'error'
        warn "Error in completion handler: #{e.message}"
        { isIncomplete: false, items: [] }
      ensure
        log_request_stage_breakdown('textDocument/completion', total_start, uri: uri, stages: stages, summary: "branch=#{branch} items=#{item_count}")
      end

      def value_chain_completions(facts, dot_recv_path, lsp_line, lsp_char, prefix)
        return nil unless dot_recv_path&.include?('.')

        chain_segments = dot_recv_path.split('.')
        return nil if chain_segments.length < 2

        first_seg = chain_segments.first
        first_type = resolve_dot_receiver_value_type(facts, first_seg, lsp_line + 1, lsp_char + 1)
        return nil unless first_type

        current_type = first_type
        chain_segments[1..].each do |seg|
          field_owner = project_field_receiver_type_for_completion(current_type)
          if field_owner.respond_to?(:field) && (field_type = field_owner.field(seg))
            current_type = field_type
          else
            return nil
          end
        end

        items = completion_items_for_value_receiver(facts, current_type, prefix)
        items.empty? ? nil : items
      end

      def completion_items_for_type_receiver(facts, receiver_type, prefix)
        methods_for_receiver_type(facts, receiver_type).filter_map do |mname, binding|
          next unless binding.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

          display_name = mname.delete_prefix("static:")
          next unless prefix.empty? || display_name.start_with?(prefix)

          params_str = format_params(binding.type.params)
          item = {
            label:      display_name,
            kind:       6,  # Method
            detail:     "#{display_name}(#{params_str}) -> #{binding.type.return_type}",
            insertText: display_name,
            sortText:   "0_#{display_name}",
            data:       completion_data(display_name),
          }
          if (snippet = snippet_for_callable(display_name, binding.type.params))
            item[:insertText] = snippet
            item[:insertTextFormat] = 2
          end
          item
        end
      end

      def resolve_nested_type_binding(facts, name)
        return { qualified_name: nil, type: nil } unless facts

        facts.types.each_value do |type|
          next unless type.respond_to?(:nested_types)
          if (nested = type.nested_types[name])
            return { qualified_name: "#{type.name}.#{name}", type: nested }
          end
        end
        { qualified_name: nil, type: nil }
      end

      def resolve_type_receiver_info(facts, receiver_name, receiver_path)
        if facts.types.key?(receiver_name)
          type = facts.types.fetch(receiver_name)
          module_name = type.respond_to?(:module_name) ? type.module_name : facts.module_name
          return { label: receiver_name, type:, module_name: }
        end

        nested = resolve_nested_type_binding(facts, receiver_name)
        return { label: nested[:qualified_name], type: nested[:type], module_name: nested[:type].module_name } if nested[:type]

        return nil unless receiver_path&.include?('.')

        module_alias, type_name = receiver_path.split('.', 2)
        return nil unless module_alias && type_name

        module_binding = facts.imports[module_alias]
        return nil unless module_binding

        type = module_binding.types[type_name]
        return nil unless type

        { label: receiver_path, type:, module_name: module_binding.name }
      end

      def resolve_static_type_receiver_method(facts, receiver_name, receiver_path, method_name)
        receiver_info = resolve_type_receiver_info(facts, receiver_name, receiver_path)
        return nil unless receiver_info

        binding = static_method_binding_for_receiver(facts, receiver_info[:type], method_name)
        return nil unless binding

        receiver_info.merge(binding:)
      end

      def static_method_binding_for_receiver(facts, receiver_type, method_name)
        methods = methods_for_receiver_type(facts, receiver_type)
        binding = methods[method_name] || methods["static:#{method_name}"]
        return nil unless binding&.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

        binding
      end

      def resolve_static_type_reference_target(uri, token, facts)
        token_end_char = token.column - 1 + token.lexeme.length
        receiver_name = @workspace.find_dot_receiver(uri, token.line - 1, token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(uri, token.line - 1, token_end_char)

        if (target = resolve_static_type_receiver_method(facts, receiver_name, receiver_path, token.lexeme))
          location = module_member_binding_location(uri, target[:module_name], token.lexeme, target[:binding])
          location ||= module_member_definition_location(uri, target[:module_name], token.lexeme)
          return target.merge(location:)
        end

        binding = static_method_binding_at_token(facts, token)
        return nil unless binding

        location = module_member_binding_location(uri, facts.module_name, token.lexeme, binding)
        location ||= module_member_definition_location(uri, facts.module_name, token.lexeme)
        {
          label: token.lexeme,
          type: binding.declared_receiver_type,
          module_name: facts.module_name,
          binding:,
          location:,
        }
      end

      def static_method_binding_at_token(facts, token)
        binding = method_binding_at_token(facts, token)
        return nil unless binding&.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static

        binding
      end

      def static_type_method_references(target, include_declaration:)
        name = target[:binding].name
        target_uri = target[:location][:uri]

        candidate_uris = nil
        if target_uri
          target_facts = @workspace.get_facts(target_uri)
          if target_facts&.module_name
            importing = @workspace.reverse_import_dependents_for(target_facts.module_name)
            candidate_uris = importing.to_a + [target_uri] if importing && !importing.empty?
          end
        end

        refs = if candidate_uris
                 @workspace.find_all_references_in(name, candidate_uris)
               else
                 @workspace.find_all_references(name)
               end
        refs.filter do |ref|
          if location_matches_reference?(target[:location], ref)
            include_declaration
          else
            static_type_method_reference?(ref, target)
          end
        end
      end

      def static_type_method_reference?(ref, target)
        token = @workspace.find_token_at(ref[:uri], ref.dig(:range, :start, :line), ref.dig(:range, :start, :character))
        return false unless token&.type == :identifier

        facts = @workspace.get_facts(ref[:uri])
        return false unless facts

        token_end_char = ref.dig(:range, :end, :character)
        receiver_name = @workspace.find_dot_receiver(ref[:uri], ref.dig(:range, :start, :line), token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(ref[:uri], ref.dig(:range, :start, :line), token_end_char)
        candidate = resolve_static_type_receiver_method(facts, receiver_name, receiver_path, token.lexeme)
        return false unless candidate

        candidate_location = module_member_binding_location(ref[:uri], candidate[:module_name], token.lexeme, candidate[:binding])
        candidate_location ||= module_member_definition_location(ref[:uri], candidate[:module_name], token.lexeme)
        same_location?(candidate_location, target[:location])
      end

      def location_matches_reference?(location, ref)
        return false unless location

        same_location?(location, {
          uri: ref[:uri],
          range: ref[:range]
        })
      end

      def same_location?(left, right)
        return false unless left && right

        left[:uri] == right[:uri] && left[:range] == right[:range]
      end

      def module_member_access_info(tokens, index)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return nil unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return nil unless receiver_index

        receiver = tokens[receiver_index]
        return nil unless receiver.type == :identifier

        { receiver: receiver.lexeme }
      end

      def completion_items_for_value_receiver(facts, receiver_type, prefix)
        items = []

        field_receiver_type = project_field_receiver_type_for_completion(receiver_type)
        if field_receiver_type.respond_to?(:fields)
          field_receiver_type.fields.each do |fname, ftype|
            next unless prefix.empty? || fname.start_with?(prefix)

            items << {
              label:      fname,
              kind:       8,  # Field
              detail:     "#{fname}: #{ftype}",
              insertText: fname,
              sortText:   "0_#{fname}",
              data:       completion_data(fname),
            }
          end
        end

        method_receiver_type = project_method_receiver_type_for_completion(receiver_type)
        methods = methods_for_receiver_type(facts, method_receiver_type)
        methods.each do |mname, binding|
          next unless prefix.empty? || mname.start_with?(prefix)

          params_str = format_params(binding.type.params)
          item = {
            label:      mname,
            kind:       6,  # Method
            detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
            insertText: mname,
            sortText:   "1_#{mname}",
            data:       completion_data(mname),
          }
          if (snippet = snippet_for_callable(mname, binding.type.params))
            item[:insertText] = snippet
            item[:insertTextFormat] = 2
          end
          items << item
        end

        items
      end

      def methods_for_receiver_type(facts, receiver_type)
        methods = {}
        return methods unless receiver_type

        receiver_candidates = [receiver_type]
        dispatch_receiver_type = method_dispatch_receiver_type_for_completion(receiver_type)
        receiver_candidates << dispatch_receiver_type if dispatch_receiver_type != receiver_type

        receiver_candidates.each do |candidate|
          facts.methods.fetch(candidate, {}).each do |name, binding|
            methods[name] ||= binding
          end
        end

        facts.imports.each_value do |module_binding|
          receiver_candidates.each do |candidate|
            module_binding.methods.fetch(candidate, {}).each do |name, binding|
              methods[name] ||= binding
            end
          end
        end
        methods
      end

      def method_dispatch_receiver_type_for_completion(receiver_type)
        return receiver_type.definition if receiver_type.is_a?(Types::StructInstance)

        if receiver_type.is_a?(Types::Nullable)
          dispatch_base_type = method_dispatch_receiver_type_for_completion(receiver_type.base)
          return receiver_type if dispatch_base_type == receiver_type.base

          return Types::Registry.nullable(dispatch_base_type)
        end

        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::Registry.generic_instance(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )

        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
      end

      def project_field_receiver_type_for_completion(type)
        project_receiver_type_for_completion(type)
      end

      def project_method_receiver_type_for_completion(type)
        project_receiver_type_for_completion(type)
      end

      def project_receiver_type_for_completion(type)
        return type.arguments.first if ref_type_name?(type)
        return type.arguments.first if pointer_type_name?(type)

        type
      end

      def field_owner_type(receiver_type)
        aggregate_type = project_field_receiver_type_for_completion(receiver_type)
        return aggregate_type.definition if aggregate_type.is_a?(Types::StructInstance)

        aggregate_type
      end

      def ref_type_name?(type)
        type.is_a?(Types::GenericInstance) && type.name == 'ref' && type.arguments.length == 1
      end

      def pointer_type_name?(type)
        type.is_a?(Types::GenericInstance) && %w[ptr const_ptr].include?(type.name) && type.arguments.length == 1
      end

      def handle_completion_resolve(params)
        data = params['data']
        return params unless data.is_a?(Hash)

        name = data['name']
        return params if name.to_s.empty?

        uri = data['uri'] || ''
        definition_entry = @workspace.find_definition_token_global(name, preferred_uri: uri)
        return params unless definition_entry

        doc_comment = @workspace.doc_comment_data_for_definition(definition_entry[:uri], definition_entry[:token])
        docs = signature_help_markdown_for_doc_comment(doc_comment)
        return params if docs.empty?

        params.merge('documentation' => { 'kind' => 'markdown', 'value' => docs })
      rescue StandardError => e
        warn "Error in completion resolve handler: #{e.message}"
        params
      end

      def import_completions(uri, lsp_line, lsp_char)
        content = @workspace.get_content(uri)
        lines = content.split("\n", -1)
        line = lines[lsp_line] || ''
        stripped = line.lstrip
        return nil unless stripped.start_with?('import ')

        import_kw_pos = line.index('import ')
        after_import = line[(import_kw_pos + 7)..].to_s

        if (as_match = after_import.match(/\s+as\s+/))
          alias_pos = as_match.begin(0)
          cursor_in_import = lsp_char - import_kw_pos - 7
          return nil if cursor_in_import > alias_pos
          after_import = after_import[0...alias_pos]
        end

        cursor_in_import = lsp_char - import_kw_pos - 7
        cursor_in_import = [[cursor_in_import, after_import.length].min, 0].max

        path_typed = after_import[0...cursor_in_import].strip

        segments = path_typed.split('.', -1)
        dir_segments = segments[0...-1]
        filter = segments.last.to_s

        current_path = uri_to_path(uri)
        return nil unless current_path

        roots = MilkTea::ModuleRoots.roots_for_path(current_path)
        fs_dir = dir_segments.join(File::SEPARATOR)

        modules = {}
        filter_lower = filter.downcase

        roots.each do |root|
          search_dir = fs_dir.empty? ? root : File.join(root, fs_dir)
          next unless File.directory?(search_dir)

          Dir.children(search_dir).sort.each do |name|
            next if name.start_with?('.')
            full_path = File.join(search_dir, name)

            if name.end_with?('.mt')
              mod_name = name.delete_suffix('.mt')
              next if mod_name.start_with?('.')
              next if full_path == current_path
              next unless filter.empty? || mod_name.downcase.start_with?(filter_lower)
              modules[mod_name] = mod_name
            elsif File.directory?(full_path) && module_dir_contains_mt?(full_path)
              next unless filter.empty? || name.downcase.start_with?(filter_lower)
              modules[name] = name
            end
          end
        end

        return nil if modules.empty?

        modules.values.sort.map do |mod_name|
          {
            label:      mod_name,
            kind:       2,
            detail:     "module #{mod_name}",
            insertText: mod_name,
            sortText:   "0_#{mod_name}",
            data:       completion_data(mod_name),
          }
        end
      end

      def module_dir_contains_mt?(dir)
        Dir.children(dir).any? do |name|
          next false if name.start_with?('.')
          full = File.join(dir, name)
          name.end_with?('.mt') || (File.directory?(full) && module_dir_contains_mt?(full))
        end
      end

      def attribute_completions(facts, uri, line, char)
        content = @workspace.get_content(uri)
        return nil unless content
        lines = content.split("\n", -1)
        line_text = lines[line] || ''
        return nil if line_text.empty?

        attr_match = line_text[0...char].match(/@\[(\w*)$/)
        return nil unless attr_match

        prefix = attr_match[1]
        items = []

        %w[packed align deprecated].each do |name|
          next unless prefix.empty? || name.start_with?(prefix)
          items << {
            label:      name,
            kind:       14,
            detail:     "built-in attribute #{name}",
            insertText: name,
            sortText:   "0_#{name}",
            data:       completion_data(name),
          }
        end

        if facts
          facts.attributes&.each do |name, _binding|
            next unless prefix.empty? || name.start_with?(prefix)
            items << {
              label:      name,
              kind:       14,
              detail:     "attribute #{name}",
              insertText: name,
              sortText:   "1_#{name}",
              data:       completion_data(name),
            }
          end
        end

        items.empty? ? nil : items
      end

      def format_string_completions(facts, uri, line, char)
        return nil unless facts

        content = @workspace.get_content(uri)
        return nil unless content
        lines = content.split("\n", -1)
        line_text = lines[line] || ''
        return nil if line_text.empty?

        text_before = line_text[0...char]
        open_pos = text_before.rindex('#{')
        return nil unless open_pos

        close_pos = text_before.index('}', open_pos)
        return nil if close_pos && close_pos < char

        prefix = text_before[(open_pos + 2)..] || ''
        items = []

        facts.values.each do |name, binding|
          next unless prefix.empty? || name.start_with?(prefix)
          items << {
            label:      name,
            kind:       13,
            detail:     "#{name}: #{binding.type}",
            insertText: name,
            sortText:   "0_#{name}",
            data:       completion_data(name),
          }
        end

        facts.functions.each do |name, _binding|
          next unless prefix.empty? || name.start_with?(prefix)
          items << {
            label:      name,
            kind:       12,
            detail:     "function #{name}",
            insertText: name,
            sortText:   "1_#{name}",
            data:       completion_data(name),
          }
        end

        frame = enclosing_completion_frame(facts, line + 1)
        if frame
          snapshot = latest_completion_snapshot(frame, line + 1, char + 1)
          if snapshot
            snapshot.bindings.each do |name, binding|
              next unless prefix.empty? || name.start_with?(prefix)
              next unless binding.respond_to?(:name) && binding.respond_to?(:type)
              items << {
                label:      name,
                kind:       13,
                detail:     "#{name}: #{binding.type}",
                insertText: name,
                sortText:   "2_#{name}",
                data:       completion_data(name),
              }
            end
          end
        end

        items.empty? ? nil : items
      end

      def named_argument_completions(facts, uri, line, char)
        return nil unless facts

        content = @workspace.get_content(uri)
        return nil unless content
        lines = content.split("\n", -1)
        line_text = lines[line] || ''
        return nil if line_text.empty?

        text_before = line_text[0...char]

        call_match = text_before.match(/([\w.]+)\s*\(\s*(?:[^)]*,\s*)\s*$/)
        call_match ||= text_before.match(/([\w.]+)\s*\(\s*$/)

        return nil unless call_match

        callable_name = call_match[1]
        prefix_match = text_before.match(/(?:^|[,\s(])(\w*)$/)
        prefix = prefix_match ? prefix_match[1] : ''

        already_provided = text_before.scan(/(\w+)\s*[=:]/).flatten.to_set

        items = []

        if (func_binding = facts.functions[callable_name])
          func_binding.type.params.each do |param|
            next if already_provided.include?(param.name)
            next unless prefix.empty? || param.name.start_with?(prefix)
            items << {
              label:      "#{param.name} = ",
              kind:       14,
              detail:     "#{param.name}: #{param.type}",
              insertText: "#{param.name} = ",
              sortText:   "0_#{param.name}",
              data:       completion_data(param.name),
            }
          end
        end

        resolved_type = facts.types[callable_name]
        if resolved_type.nil? && callable_name.include?('.')
          parts = callable_name.split('.', 2)
          mod_binding = facts.imports[parts[0]]
          resolved_type = mod_binding&.types&.[](parts[1]) if mod_binding
        end

        if resolved_type&.respond_to?(:fields) && !resolved_type.fields.empty?
          resolved_type.fields.each do |fname, ftype|
            next if already_provided.include?(fname)
            next unless prefix.empty? || fname.start_with?(prefix)
            items << {
              label:      "#{fname} = ",
              kind:       8,
              detail:     "#{fname}: #{ftype}",
              insertText: "#{fname} = ",
              sortText:   "0_#{fname}",
              data:       completion_data(fname),
            }
          end
        end

        items.empty? ? nil : items
      end

      def specialization_completions(facts, _uri, line, char)
        return nil unless facts

        content = @workspace.get_content(_uri)
        return nil unless content
        lines = content.split("\n", -1)
        line_text = lines[line] || ''
        return nil if line_text.empty?

        text_before = line_text[0...char]
        sp_match = text_before.match(/([\w.]+)\[(.*)$/)
        return nil unless sp_match

        prefix = sp_match[2]
        items = []

        facts.types.each do |name, _type|
          next unless prefix.empty? || name.start_with?(prefix)
          items << {
            label:      name,
            kind:       5,
            detail:     "type #{name}",
            insertText: name,
            sortText:   "0_#{name}",
            data:       completion_data(name),
          }
        end

        items.empty? ? nil : items
      end
      end
    end
  end
end
