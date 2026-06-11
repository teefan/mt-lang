# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerReferences
        private

      def handle_references(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        result_count = 0
        result_state = 'miss'

        token = measure_perf_stage(stages, 'token') { @workspace.find_token_at(uri, lsp_line, lsp_char) }
        unless token&.type == :identifier
          result_state = 'not-identifier'
          return []
        end

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        include_declaration = params.dig('context', 'includeDeclaration') != false
        target = facts ? measure_perf_stage(stages, 'static_target') { resolve_static_type_reference_target(uri, token, facts) } : nil
        if target
          refs = measure_perf_stage(stages, 'static_refs') { static_type_method_references(target, include_declaration: include_declaration) }
          result_count = refs.length
          result_state = refs.empty? ? 'miss' : 'hit'
          return refs
        end

        if facts
          scoped_refs = measure_perf_stage(stages, 'scoped_refs') do
            scoped_local_reference_locations(uri, token, lsp_line, lsp_char, facts, include_declaration: include_declaration)
          end
          unless scoped_refs.nil?
            result_count = scoped_refs.length
            result_state = scoped_refs.empty? ? 'miss' : 'hit'
            return scoped_refs
          end
        end

        if facts && module_level_name?(facts, token.lexeme)
          refs = measure_perf_stage(stages, 'module_refs') { module_level_reference_locations(uri, token.lexeme, facts, include_declaration: include_declaration) }
          result_count = refs.length
          result_state = refs.empty? ? 'miss' : 'hit'
          return refs
        end

        unless facts
          ast = @workspace.get_ast(uri)
          if ast && module_level_ast_name?(ast, token.lexeme)
            refs = measure_perf_stage(stages, 'module_refs') { module_level_reference_locations(uri, token.lexeme, nil, include_declaration: include_declaration) }
            result_count = refs.length
            result_state = refs.empty? ? 'miss' : 'hit'
            return refs
          end
        end

        refs = measure_perf_stage(stages, 'refs_scan') { @workspace.find_all_references(token.lexeme) }
        if include_declaration
          result_count = refs.length
          result_state = refs.empty? ? 'miss' : 'hit'
          return refs
        end

        found = measure_perf_stage(stages, 'definition_lookup') { @workspace.find_definition_token_global(token.lexeme, preferred_uri: uri) }
        unless found
          result_count = refs.length
          result_state = refs.empty? ? 'miss' : 'hit'
          return refs
        end

        def_uri = found[:uri]
        def_line = found[:token].line - 1
        def_char = found[:token].column - 1
        filtered = measure_perf_stage(stages, 'filter') do
          refs.reject do |r|
            r[:uri] == def_uri &&
              r[:range][:start][:line] == def_line &&
              r[:range][:start][:character] == def_char
          end
        end
        result_count = filtered.length
        result_state = filtered.empty? ? 'miss' : 'hit'
        filtered
      rescue StandardError => e
        result_state = 'error'
        warn "Error in references handler: #{e.message}"
        []
      ensure
        log_request_stage_breakdown('textDocument/references', total_start, uri: uri, stages: stages, summary: "result=#{result_state} refs=#{result_count}")
      end

      def handle_document_link(params)
        uri = params['textDocument']['uri']
        file_path = uri_to_path(uri)
        return [] unless file_path

        tokens = @workspace.get_tokens(uri)
        return [] unless tokens

        tokens.filter_map do |token|
          resource_document_link(uri, file_path, token)
        end
      rescue StandardError => e
        warn "Error in documentLink handler: #{e.message}"
        []
      end

      def handle_document_link_resolve(params)
        target = params['target']
        if target && target.start_with?('file://')
          path = uri_to_path(target)
          if path && File.file?(path)
            first_line = File.open(path, &:readline).strip rescue nil
            params.merge(
              'tooltip' => first_line ? "#{path}\n#{first_line}" : path
            )
          else
            params
          end
        else
          params
        end
      rescue StandardError => e
        warn "Error in documentLink/resolve handler: #{e.message}"
        params
      end

      def module_level_name?(facts, name)
        return true if facts.functions.key?(name) || facts.types.key?(name) || facts.values.key?(name)

        facts.methods.each_value do |methods|
          return true if methods.key?(name) || methods.key?("static:#{name}")
        end
        false
      end

      def module_level_ast_name?(ast, name)
        each_ast_node(ast) do |node|
          return true if module_level_declaration_node?(node) && node.respond_to?(:name) && node.name == name
        end
        false
      end

      def module_level_reference_locations(uri, name, facts, include_declaration:)
        ast = @workspace.get_ast(uri)
        return [] unless ast

        results = []
        each_ast_node(ast) do |node|
          if node.is_a?(AST::Identifier) && node.name == name
            range = ast_name_range(node.name, node.line, node.column)
            next unless range

            results << {
              uri: uri,
              range: {
                start: { line: range[:line] - 1, character: range[:column] - 1 },
                end: { line: range[:line] - 1, character: range[:column] - 1 + name.length },
              },
            }
          elsif include_declaration && node.respond_to?(:name) && node.name == name && module_level_declaration_node?(node)
            range = declaration_name_range(node)
            unless range
              range = declaration_name_range_fallback(node, uri, name)
            end
            next unless range

            results << {
              uri: uri,
              range: {
                start: { line: range[:line] - 1, character: range[:column] - 1 },
                end: { line: range[:line] - 1, character: range[:column] - 1 + name.length },
              },
            }
          elsif node.is_a?(AST::MemberAccess) && node.member == name && node.line && node.column
            row = get_content_line(uri, node.line - 1)
            if row
              member_col = find_member_column_in_line(row, node.column, name)
              if member_col
                results << {
                  uri: uri,
                  range: {
                    start: { line: node.line - 1, character: member_col },
                    end: { line: node.line - 1, character: member_col + name.length },
                  },
                }
              end
            end
          end
        end

        if facts&.module_name
          importing_uris = @workspace.reverse_import_dependents_for(facts.module_name)
          if importing_uris && !importing_uris.empty?
            cross_refs = @workspace.find_all_references_in(name, importing_uris.to_a - [uri])
            results.concat(cross_refs)
          end
        end

        results.uniq { |r| [r[:uri], r.dig(:range, :start, :line), r.dig(:range, :start, :character)] }
      end

      def get_content_line(uri, lsp_line)
        content = @workspace.get_content(uri)
        return nil unless content

        content.split("\n", -1)[lsp_line]
      rescue StandardError
        nil
      end

      def find_member_column_in_line(line, receiver_start_col, member_name)
        idx = receiver_start_col
        while idx < line.length && line[idx] =~ /[A-Za-z0-9_.]/
          idx += 1
        end

        dot_idx = line.index('.', receiver_start_col)
        return nil unless dot_idx && dot_idx < idx

        member_start = dot_idx + 1
        match = line[member_start, member_name.length]
        return nil unless match == member_name

        member_start
      end

      def module_level_declaration_node?(node)
        node.is_a?(AST::FunctionDef) ||
          node.is_a?(AST::MethodDef) ||
          node.is_a?(AST::ExternFunctionDecl) ||
          node.is_a?(AST::ForeignFunctionDecl) ||
          node.is_a?(AST::ConstDecl) ||
          node.is_a?(AST::VarDecl) ||
          node.is_a?(AST::TypeAliasDecl) ||
          node.is_a?(AST::StructDecl) ||
          node.is_a?(AST::UnionDecl) ||
          node.is_a?(AST::EnumDecl) ||
          node.is_a?(AST::FlagsDecl) ||
          node.is_a?(AST::OpaqueDecl)
      end

      def declaration_name_range_fallback(node, uri, name)
        return nil unless node.respond_to?(:line) && node.line

        row = get_content_line(uri, node.line - 1)
        return nil unless row

        col = row.index(/\b#{Regexp.escape(name)}\b/)
        return nil unless col

        { name: name, line: node.line, column: col + 1, length: name.length }
      rescue StandardError
        nil
      end

      def handle_document_highlight(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return [] unless token&.type == :identifier

        if (facts = @workspace.get_facts(uri))
          scoped = begin
            scoped_local_reference_locations(uri, token, lsp_line, lsp_char, facts, include_declaration: true)
          rescue StandardError
            nil
          end
          unless scoped.nil?
            return scoped.map { |entry| { range: entry[:range], kind: 1 } }
          end
        end

        toks = @workspace.get_tokens(uri) || []
        toks.select { |t| t.type == :identifier && t.lexeme == token.lexeme }
            .map    { |t| { range: token_to_range(t), kind: 1 } }
      rescue StandardError => e
        warn "Error in documentHighlight handler: #{e.message}"
        []
      end

      def handle_workspace_symbol(params)
        query = (params['query'] || '').downcase

        @workspace.index_workspace(@root_uri) if @root_uri

        results = []
        @workspace.all_documents.each do |uri|
          @workspace.get_symbols(uri).each do |sym|
            next unless query.empty? || sym[:name].downcase.include?(query)

            results << format_symbol(sym, uri)
          end
        end

        results
      rescue StandardError => e
        warn "Error in workspace/symbol handler: #{e.message}"
        []
      end

      def resource_document_link(uri, file_path, token)
        return nil unless [:string, :cstring].include?(token.type)

        literal = token.literal
        return nil unless literal.is_a?(String)
        return nil unless path_like_string_literal?(literal)

        resolved_path = resolve_document_link_path(file_path, literal)
        return nil unless resolved_path

        {
          range: token_to_range(token),
          target: path_to_uri(resolved_path),
          tooltip: "Open linked file"
        }
      end

      def path_like_string_literal?(literal)
        literal.include?('/') || literal.include?(File::SEPARATOR)
      end

      def resolve_document_link_path(source_path, literal)
        base_dir = File.dirname(source_path)
        candidate = if Pathname.new(literal).absolute?
                      literal
                    else
                      File.expand_path(literal, base_dir)
                    end
        return nil unless File.exist?(candidate)

        candidate
      rescue StandardError
        nil
      end
      end
    end
  end
end
