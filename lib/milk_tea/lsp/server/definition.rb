# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerDefinition
        private

      def handle_definition(params)
        handle_definition_request('textDocument/definition', params, error_label: 'definition')
      end

      def handle_declaration(params)
        handle_definition_request('textDocument/declaration', params, error_label: 'declaration')
      end

      def handle_type_definition(params)
        handle_definition_request('textDocument/typeDefinition', params, error_label: 'typeDefinition')
      end

      def handle_implementation(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri = params.dig('textDocument', 'uri')
        result_state = 'miss'

        locations = resolve_implementation_locations(params, stages: stages)
        result_state = locations.empty? ? 'miss' : 'hit'
        locations
      rescue StandardError => e
        result_state = 'error'
        warn "Error in implementation handler: #{e.message}"
        []
      ensure
        log_request_stage_breakdown('textDocument/implementation', total_start, uri: uri, stages: stages, summary: "result=#{result_state}")
      end

      def handle_definition_request(method_name, params, error_label:)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri = params.dig('textDocument', 'uri')
        result_state = 'miss'

        location = resolve_definition_location(params, stages: stages)
        result_state = location ? 'hit' : 'miss'
        location
      rescue StandardError => e
        result_state = 'error'
        warn "Error in #{error_label} handler: #{e.message}"
        nil
      ensure
        log_request_stage_breakdown(method_name, total_start, uri: uri, stages: stages, summary: "result=#{result_state}")
      end

      def resolve_definition_location(params, stages: nil)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        context = measure_perf_stage(stages, 'context') { token_context_at(uri, lsp_line, lsp_char) }
        token = context&.fetch(:token, nil)
        return nil unless token&.type == :identifier

        tokens = context[:tokens]
        token_index = context[:token_index]
        return nil if token_index && module_declaration_info_at(tokens, token_index)
        return nil if token_index && builtin_hover_info(token.lexeme, tokens, token_index)

        import_info = token_index ? measure_perf_stage(stages, 'import_path') { import_path_info_at(tokens, token_index) } : nil
        if import_info
          return module_definition_location(uri, import_info[:module_name])
        end

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        if facts
          facts_location = measure_perf_stage(stages, 'facts_lookup') do
            location = nil
            dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
            dot_receiver_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
            imported_module_name = dot_receiver ? (facts.imports[dot_receiver]&.name || imported_module_name_from_ast(uri, dot_receiver)) : nil

            if token_index && (field_location = resolve_field_member_definition_location(uri, facts, tokens, token_index))
              location = field_location
            elsif token_index && (enum_member_location = resolve_enum_member_definition_location(uri, facts, tokens, token_index))
              location = enum_member_location
            elsif token_index && imported_module_name && module_member_access_info(tokens, token_index)
              location = module_member_definition_location(uri, imported_module_name, token.lexeme)
              location ||= module_definition_location(uri, imported_module_name)
            elsif (type_method = resolve_static_type_receiver_method(facts, dot_receiver, dot_receiver_path, token.lexeme))
              location = module_member_binding_location(uri, type_method[:module_name], token.lexeme, type_method[:binding]) ||
                module_member_definition_location(uri, type_method[:module_name], token.lexeme) ||
                module_definition_location(uri, type_method[:module_name])
            else
              if imported_module_name
                location = module_member_definition_location(uri, imported_module_name, token.lexeme) || module_definition_location(uri, imported_module_name)
              elsif facts.imports.key?(token.lexeme)
                module_name = facts.imports.fetch(token.lexeme).name
                location = module_member_definition_location(uri, module_name, token.lexeme)
                location ||= module_definition_location(uri, module_name)
              elsif (module_name = imported_module_name_from_ast(uri, token.lexeme))
                location = module_definition_location(uri, module_name)
              end
            end

            location
          end

          return facts_location if facts_location
        end

        found = measure_perf_stage(stages, 'global_lookup') do
          @workspace.find_definition_token_global(
            token.lexeme,
            preferred_uri: uri,
            before_line: lsp_line + 1,
            before_char: lsp_char + 1,
          )
        end
        return nil unless found

        {
          uri: found[:uri],
          range: token_to_range(found[:token])
        }
      end

      def resolve_field_member_definition_location(current_uri, facts, tokens, token_index)
        chain = member_access_chain_at(tokens, token_index)
        return nil unless chain

        hovered_segment = chain[:segments].find { |segment| segment[:token_index] == token_index }
        return nil unless hovered_segment && hovered_segment[:position].positive?

        current_type = resolve_dot_receiver_value_type(
          facts,
          chain[:segments].first[:name],
          chain[:line],
          chain[:char],
        )
        return nil unless current_type

        chain[:segments][1..hovered_segment[:position]].each do |segment|
          field_receiver_type = project_field_receiver_type_for_completion(current_type)
          if field_receiver_type.respond_to?(:field) && (field_type = field_receiver_type.field(segment[:name]))
            return field_definition_location(current_uri, field_receiver_type, segment[:name]) if segment[:token_index] == token_index

            current_type = field_type
            next
          end

          if segment[:token_index] == token_index
            method_receiver_type = project_method_receiver_type_for_completion(current_type)
            method_info = member_method_info_for_receiver_type(facts, method_receiver_type, segment[:name])
            return nil unless method_info

            return module_member_binding_location(current_uri, method_info[:module_name], segment[:name], method_info[:binding]) ||
              module_member_definition_location(current_uri, method_info[:module_name], segment[:name])
          end

          break
        end

        nil
      end

      def resolve_implementation_locations(params, stages: nil)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = measure_perf_stage(stages, 'token') { @workspace.find_token_at(uri, lsp_line, lsp_char) }
        return [] unless token&.type == :identifier

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        return [] unless facts

        target = measure_perf_stage(stages, 'target_lookup') { resolve_interface_method_target_at_token(facts, token) }
        if target
          return measure_perf_stage(stages, 'implementation_lookup') do
            interface_method_implementation_locations(target[:interface], target[:method])
          end
        end

        interface_binding = measure_perf_stage(stages, 'binding_lookup') do
          resolve_interface_binding_at_position(uri, facts, token, lsp_line, lsp_char)
        end
        return [] unless interface_binding

        measure_perf_stage(stages, 'implementation_lookup') { interface_implementation_locations(interface_binding) }
      end

      def module_definition_location(current_uri, module_name)
        path = module_path_for_name(current_uri, module_name)
        return nil unless path

        {
          uri: path_to_uri(File.expand_path(path)),
          range: {
            start: { line: 0, character: 0 },
            end: { line: 0, character: 0 }
          }
        }
      end

      def module_member_definition_location(current_uri, module_name, member_name)
        path = module_path_for_name(current_uri, module_name)
        return nil unless path

        token = find_definition_token_in_file(path, member_name)
        return nil unless token

        {
          uri: path_to_uri(File.expand_path(path)),
          range: token_to_range(token)
        }
      end

      def field_definition_location(current_uri, receiver_type, field_name)
        owner_type = field_owner_type(receiver_type)
        return nil unless owner_type&.respond_to?(:name)

        path = module_path_for_name(current_uri, owner_type.module_name)
        return nil unless path

        token = find_field_token_in_type(path, owner_type.name, field_name, current_uri: current_uri)
        return nil unless token

        {
          uri: path_to_uri(File.expand_path(path)),
          range: token_to_range(token)
        }
      end

      def enum_member_definition_location(current_uri, module_name, type_name, member_name)
        path = module_path_for_name(current_uri, module_name)
        return nil unless path

        token = find_enum_member_token_in_file(path, type_name, member_name)
        return nil unless token

        {
          uri: path_to_uri(File.expand_path(path)),
          range: token_to_range(token)
        }
      end

      def module_member_binding_location(current_uri, module_name, member_name, binding)
        path = module_path_for_name(current_uri, module_name)
        return nil unless path

        ast = binding&.ast
        if ast&.line && ast.respond_to?(:column) && ast.column
          start_line = ast.line - 1
          start_char = ast.column - 1

          return {
            uri: path_to_uri(File.expand_path(path)),
            range: {
              start: { line: start_line, character: start_char },
              end: { line: start_line, character: start_char + member_name.length }
            }
          }
        end

        module_member_definition_location(current_uri, module_name, member_name)
      end

      def module_path_for_name(current_uri, module_name)
        current_path = uri_to_path(current_uri)
        return nil unless current_path
        return current_path if module_name.nil? || module_name.empty?

        current_facts = @workspace.get_facts(current_uri)
        return current_path if current_facts&.module_name == module_name

        resolution = DependencyResolution.resolve(current_path, mode: @workspace.dependency_resolution_mode)
        module_roots = if resolution.ok?
                         MilkTea::ModuleRoots.roots_for_path(current_path, locked: resolution.locked)
                       else
                         MilkTea::ModuleRoots.roots_for_path(current_path)
                       end
        relative_path = File.join(*module_name.split('.')) + '.mt'
        resolved_path = module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |candidate| File.file?(candidate) }
        return resolved_path if resolved_path

        workspace_root = @root_uri ? uri_to_path(@root_uri) : nil
        return nil unless workspace_root && File.directory?(workspace_root)

        workspace_candidate = File.join(workspace_root, relative_path)
        return workspace_candidate if File.file?(workspace_candidate)

        nil
      rescue PackageLockError
        module_roots = MilkTea::ModuleRoots.roots_for_path(current_path)
        relative_path = File.join(*module_name.split('.')) + '.mt'
        resolved_path = module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |candidate| File.file?(candidate) }
        return resolved_path if resolved_path

        workspace_root = @root_uri ? uri_to_path(@root_uri) : nil
        return nil unless workspace_root && File.directory?(workspace_root)

        workspace_candidate = File.join(workspace_root, relative_path)
        return workspace_candidate if File.file?(workspace_candidate)

        nil
      end

      def imported_module_name_from_ast(uri, alias_name)
        return nil if alias_name.nil? || alias_name.empty?

        ast = @workspace.get_ast(uri)
        return nil unless ast

        import = ast.imports.find do |entry|
          resolved_alias = entry.alias_name || entry.path.parts.last
          resolved_alias == alias_name
        end
        import&.path&.to_s
      rescue StandardError
        nil
      end

      def find_definition_token_in_file(path, name)
        tokens = definition_file_tokens(path)

        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless MilkTea::LSP::Workspace::DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier && id_tok.lexeme == name

          return id_tok
        end

        nil
      rescue StandardError
        nil
      end

      def find_field_token_in_type(path, type_name, field_name, current_uri: nil)
        tokens = definition_lookup_tokens(path, current_uri: current_uri)

        tokens.each_with_index do |token, index|
          next unless [:struct, :union].include?(token.type)

          name_index = next_non_trivia_token_index(tokens, index + 1)
          next unless name_index && tokens[name_index].type == :identifier && tokens[name_index].lexeme == type_name

          field_token = find_field_token_in_body(tokens, index, field_name)
          return field_token if field_token
        end

        nil
      rescue StandardError
        nil
      end

      def find_field_token_in_body(tokens, header_index, field_name)
        header = tokens[header_index]
        i = header_index + 1

        while i < tokens.length
          token = tokens[i]

          if token.line > header.line && ![:newline, :indent, :dedent, :eof].include?(token.type) &&
              first_non_trivia_token_on_line?(tokens, i) && token.column <= header.column
            break
          end

          if token.type == :identifier && token.lexeme == field_name && token.line > header.line &&
              first_non_trivia_token_on_line?(tokens, i) && token.column > header.column
            colon_index = next_non_trivia_token_index(tokens, i + 1)
            return token if colon_index && tokens[colon_index].type == :colon
          end

          i += 1
        end

        nil
      end

      def find_enum_member_token_in_file(path, type_name, member_name)
        tokens = definition_file_tokens(path)

        tokens.each_with_index do |token, index|
          next unless [:enum, :flags].include?(token.type)

          name_index = next_non_trivia_token_index(tokens, index + 1)
          next unless name_index && tokens[name_index].type == :identifier && tokens[name_index].lexeme == type_name

          member_token = find_enum_member_token_in_body(tokens, index, member_name)
          return member_token if member_token
        end

        nil
      rescue StandardError
        nil
      end

      def find_enum_member_token_in_body(tokens, header_index, member_name)
        header = tokens[header_index]
        i = header_index + 1

        while i < tokens.length
          token = tokens[i]

          if token.line > header.line && ![:newline, :indent, :dedent, :eof].include?(token.type) &&
              first_non_trivia_token_on_line?(tokens, i) && token.column <= header.column
            break
          end

          if token.type == :identifier && token.lexeme == member_name && token.line > header.line &&
              first_non_trivia_token_on_line?(tokens, i) && token.column > header.column
            return token
          end

          i += 1
        end

        nil
      end

      def enum_member_value_text(current_uri, module_name, type_name, member_name)
        path = module_path_for_name(current_uri, module_name)
        return nil unless path

        declaration = definition_file_ast(path)&.declarations&.find do |decl|
          (decl.is_a?(AST::EnumDecl) || decl.is_a?(AST::FlagsDecl)) && decl.name == type_name
        end
        return nil unless declaration

        member = declaration.members.find { |candidate| candidate.name == member_name }
        return nil unless member&.value

        MilkTea::PrettyPrinter::ASTFormatter.new.send(:render_expression, member.value)
      rescue StandardError
        nil
      end

      def definition_file_mtime_key(path)
        stat = File.stat(path)
        "#{stat.mtime.to_i}:#{stat.mtime.nsec}"
      rescue StandardError
        'missing'
      end

      def definition_file_tokens(path, mtime_key: nil)
        cache_key = "#{path}:#{mtime_key || definition_file_mtime_key(path)}"
        @definition_file_token_cache[cache_key] ||= begin
          MilkTea::Lexer.lex(File.read(path), path: path_to_uri(path))
        end
      end

      def definition_lookup_tokens(path, current_uri: nil)
        current_path = current_uri ? uri_to_path(current_uri) : nil
        if current_path && File.expand_path(current_path) == File.expand_path(path)
          workspace_tokens = @workspace.get_tokens(current_uri)
          return workspace_tokens if workspace_tokens
        end

        definition_file_tokens(path)
      end

      def definition_file_ast(path)
        mtime_key = definition_file_mtime_key(path)
        cache_key = "#{path}:#{mtime_key}"
        @definition_file_ast_cache[cache_key] ||= begin
          MilkTea::Parser.parse(nil, path: path_to_uri(path), tokens: definition_file_tokens(path, mtime_key: mtime_key))
        end
      end

      def resolve_interface_binding_at_position(uri, facts, token, lsp_line, lsp_char)
        binding = facts.interfaces[token.lexeme]
        return binding if binding

        dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
        return nil unless dot_receiver

        facts.imports[dot_receiver]&.interfaces&.fetch(token.lexeme, nil)
      end

      def resolve_interface_method_target_at_token(facts, token)
        facts.interfaces.each_value do |interface_binding|
          method_binding = interface_binding.methods[token.lexeme]
          next unless method_binding
          next unless method_binding.ast.line == token.line
          next unless method_binding.ast.respond_to?(:column) && method_binding.ast.column == token.column

          return { interface: interface_binding, method: method_binding }
        end

        nil
      end

      def interface_implementation_locations(interface_binding)
        seen = Set.new
        @workspace.all_documents.filter_map do |doc_uri|
          facts = @workspace.get_facts(doc_uri)
          next unless facts

          facts.implemented_interfaces.each_with_object([]) do |(receiver_type, interfaces), locations|
            next unless interfaces.any? { |candidate| same_interface_binding?(candidate, interface_binding) }

            location = interface_receiver_definition_location(doc_uri, receiver_type)
            next unless location

            key = [location[:uri], location.dig(:range, :start, :line), location.dig(:range, :start, :character)]
            next if seen.include?(key)

            seen << key
            locations << location
          end
        end.flatten
      end

      def interface_method_implementation_locations(interface_binding, interface_method)
        seen = Set.new
        @workspace.all_documents.filter_map do |doc_uri|
          facts = @workspace.get_facts(doc_uri)
          next unless facts

          facts.implemented_interfaces.each_with_object([]) do |(receiver_type, interfaces), locations|
            next unless interfaces.any? { |candidate| same_interface_binding?(candidate, interface_binding) }

            method = methods_for_receiver_type(facts, receiver_type)[interface_method.name]
            next unless method

            module_name = receiver_module_name(receiver_type)
            location = module_member_binding_location(doc_uri, module_name, interface_method.name, method)
            location ||= module_member_definition_location(doc_uri, module_name, interface_method.name)
            next unless location

            key = [location[:uri], location.dig(:range, :start, :line), location.dig(:range, :start, :character)]
            next if seen.include?(key)

            seen << key
            locations << location
          end
        end.flatten
      end

      def interface_receiver_definition_location(current_uri, receiver_type)
        receiver_type = receiver_type.definition if receiver_type.is_a?(Types::StructInstance)

        if receiver_type.module_name.nil? || receiver_type.module_name.empty?
          token = local_type_definition_token(current_uri, receiver_type.name)
          token ||= @workspace.find_definition_token(current_uri, receiver_type.name)
          return { uri: current_uri, range: token_to_range(token) } if token
        end

        module_member_definition_location(current_uri, receiver_type.module_name, receiver_type.name)
      end

      def receiver_module_name(receiver_type)
        receiver_type = receiver_type.definition if receiver_type.is_a?(Types::StructInstance)

        receiver_type.module_name
      end

      def local_type_definition_token(uri, name)
        tokens = @workspace.get_tokens(uri)
        return nil unless tokens

        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless [:struct, :opaque].include?(kw_tok.type)
          next unless id_tok.type == :identifier && id_tok.lexeme == name

          return id_tok
        end

        nil
      end

      def same_interface_binding?(left, right)
        left.name == right.name && left.module_name == right.module_name
      end
      end
    end
  end
end
