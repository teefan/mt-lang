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
