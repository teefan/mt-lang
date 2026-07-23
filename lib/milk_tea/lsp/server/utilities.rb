# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerUtilities
        private

      def perf_logging?
        @perf_logging ||= !ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s.empty?
      end

      def perf_verbose?
        @perf_verbose ||= ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s == 'verbose'
      end

      def perf_breakdown_logging?(elapsed_ms)
        perf_logging? && (perf_verbose? || elapsed_ms > Workspace::PERF_LOG_THRESHOLD_MS)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(start_time)
        ((monotonic_time - start_time) * 1000).round(1)
      end

      def log_perf_breakdown(method_name, elapsed_ms_value, detail)
        return unless perf_breakdown_logging?(elapsed_ms_value)

        id_detail = @current_request_id ? " id=#{@current_request_id}" : ''
        warn "[LSP perf] breakdown #{method_name} #{elapsed_ms_value}ms#{id_detail} #{detail}"
      end

      def new_perf_stages
        perf_logging? ? [] : nil
      end

      def measure_perf_stage(stages, name)
        return yield unless stages

        start_time = monotonic_time
        result = yield
        stages << [name, elapsed_ms(start_time)]
        result
      end

      def log_request_stage_breakdown(method_name, total_start, uri: nil, stages: nil, summary: nil)
        return unless total_start

        detail = []
        detail << "uri=#{shorten_uri(uri) || uri}" if uri
        detail << summary if summary && !summary.empty?
        unless stages.nil? || stages.empty?
          detail << "stages_ms=#{stages.map { |name, ms| "#{name}:#{ms}" }.join(',')}"
        end

        log_perf_breakdown(method_name, elapsed_ms(total_start), detail.join(' '))
      end

      def perf_log_context(method_name, params, verbose: false)
        return "" unless params.is_a?(Hash)

        summary = summarize_lsp_params(method_name, params)
        return summary.empty? ? "" : " #{summary}" if verbose

        text_document = hget(params, 'textDocument')
        uri = text_document.is_a?(Hash) ? hget(text_document, 'uri') : nil
        bits = []
        bits << "uri=#{shorten_uri(uri) || uri}" if uri

        if method_name == 'textDocument/didChange'
          changes = hget(params, 'contentChanges')
          bits << "changes=#{changes.length}" if changes.respond_to?(:length)
        end

        bits.empty? ? "" : " #{bits.join(' ')}"
      rescue StandardError
        ""
      end

      def summarize_lsp_params(method_name, params)
        return "" unless params.is_a?(Hash)

        text_document = hget(params, 'textDocument')
        uri = text_document.is_a?(Hash) ? hget(text_document, 'uri') : nil
        file_path = uri_to_path(uri)
        short_uri = shorten_uri(uri)
        position = hget(params, 'position')
        line = position.is_a?(Hash) ? hget(position, 'line') : nil
        char = position.is_a?(Hash) ? hget(position, 'character') : nil
        pos = "#{line}:#{char}" if line && char
        query = hget(params, 'query')

        bits = []
        bits << "uri=#{short_uri || uri}" if uri
        bits << "pos=#{pos}" if pos
        if file_path && line.is_a?(Integer) && char.is_a?(Integer)
          bits << "loc=#{file_path}:#{line + 1}:#{char + 1}"
        end
        bits << "query=#{query.inspect}" if query
        bits << "keys=#{params.keys.map(&:to_s).sort.join(',')}" unless params.empty?

        if method_name == 'textDocument/didChange'
          changes = hget(params, 'contentChanges')
          bits << "changes=#{changes.length}" if changes.respond_to?(:length)
        end

        bits.join(' ')
      rescue StandardError
        ""
      end

      def hget(hash, key)
        return nil unless hash.is_a?(Hash)

        hash[key] || hash[key.to_sym]
      end

      def shorten_uri(uri)
        return nil unless uri
        return uri unless uri.is_a?(String) && uri.start_with?('file://')

        file_path = uri_to_path(uri)
        return uri unless file_path

        root_path = uri_to_path(@root_uri)
        return uri unless root_path

        begin
          relative = Pathname.new(file_path).relative_path_from(Pathname.new(root_path)).to_s
          return relative unless relative.start_with?('..')
        rescue StandardError
          # Keep the original URI if path normalization fails.
        end

        uri
      end

      def uri_to_path(uri)
        parsed = URI.parse(uri)
        return nil unless parsed.scheme == 'file'

        CGI.unescape(parsed.path)
      rescue URI::InvalidURIError
        nil
      end

      def library_uri?(uri)
        return false unless @root_uri

        file_path = uri_to_path(uri)
        root_path = uri_to_path(@root_uri)
        return false unless file_path && root_path

        !file_path.start_with?(root_path)
      rescue StandardError
        false
      end

      def skip_expensive_source_fix_all?(uri, content)
        !skip_expensive_work_reason(uri, content).nil?
      rescue StandardError
        false
      end

      def skip_expensive_work_reason(uri, content)
        return 'library-uri' if library_uri?(uri)

        # Heuristic thresholds to avoid expensive full-file lint-fix runs.
        return 'large-bytes' if content.bytesize > 200_000
        return 'large-lines' if content.count("\n") > 1200

        nil
      rescue StandardError
        nil
      end

      def handle_did_change_watched_files(params)
        changes = params['changes'] || []
        affected_uris = Set.new
        changes.each do |change|
          uri = change['uri']
          type = change['type']
          next unless uri

          affected_uris.merge(@workspace.apply_watched_file_change(uri, type))
        end

        invalidate_document_caches_for(affected_uris)
        affected_uris.each do |affected_uri|
          schedule_diagnostics(affected_uri, force: true, lint_tier: :full) unless @workspace.background_document?(affected_uri)
        end
        refresh_client_semantic_tokens if affected_uris.any?
        nil
      end

      def invalidate_document_caches(uri)
        @semantic_tokens_cache.delete(uri)
        @semantic_tokens_delta_cache.delete(uri)
        @fixall_cache.delete(uri)
        path = uri_to_path(uri)
        if path
          prefix = "#{path}:"
          @definition_file_token_cache.delete_if { |key, _| key.start_with?(prefix) }
          @definition_file_ast_cache.delete_if { |key, _| key.start_with?(prefix) }
        end
      end

      def invalidate_document_caches_for(uris)
        uris.each { |uri| invalidate_document_caches(uri) }
      end

      def refresh_open_document_dependency_state(changed_uri, previous_content: nil, current_content: nil)
        return [] unless dependency_refresh_required_for_edit?(changed_uri, previous_content, current_content)

        affected_uris = @workspace.refresh_open_document_dependency_caches(changed_uri)
        invalidate_document_caches_for(affected_uris)
        affected_uris.each do |affected_uri|
          schedule_diagnostics(affected_uri, force: true, lint_tier: :full) unless @workspace.background_document?(affected_uri)
        end
        affected_uris
      end

      def request_cancelled?(id)
        return false if id.nil?

        @cancelled_requests_mutex.synchronize do
          @cancelled_request_ids.include?(id)
        end
      end

      def clear_cancelled_request(id)
        return if id.nil?

        @cancelled_requests_mutex.synchronize do
          @cancelled_request_ids.delete(id)
        end
      end

      def format_symbol(sym, uri)
        line = sym[:line].to_i
        col  = sym[:column].to_i

        {
          name:     sym[:name],
          kind:     symbol_kind(sym[:kind]),
          location: {
            uri:   uri,
            range: {
              start: { line: line - 1, character: col - 1 },
              end:   { line: line - 1, character: col - 1 + sym[:name].length }
            }
          }
        }
      end

      def format_document_symbol(sym)
        line = sym[:line].to_i
        col  = sym[:column].to_i

        {
          name:           sym[:name],
          kind:           symbol_kind(sym[:kind]),
          range:          {
            start: { line: line - 1, character: col - 1 },
            end:   { line: line - 1, character: col - 1 + sym[:name].length }
          },
          selectionRange: {
            start: { line: line - 1, character: col - 1 },
            end:   { line: line - 1, character: col - 1 + sym[:name].length }
          }
        }
      end

      def symbol_kind(kind)
        case kind
        when 'function'   then 12 # Function
        when 'interface'  then 11 # Interface
        when 'struct'     then 23 # Struct
        when 'union'      then 23 # Struct (union is a struct variant)
        when 'enum'       then 10 # Enum
        when 'flags'      then 10 # Enum (flags is an enum variant)
        when 'variant'    then 23 # Struct (variant is a struct variant)
        when 'type_alias' then 5  # Class
        when 'constant'   then 14 # Constant
        when 'variable'   then 13 # Variable
        when 'event'      then 24 # Event
        when 'type_param' then 26 # TypeParameter
        else 1 # File
        end
      end

      def current_word_prefix(uri, lsp_line, lsp_char)
        content = @workspace.get_content(uri)
        lines   = content.split("\n", -1)
        line    = lines[lsp_line] || ''
        # Walk backwards from cursor to find start of current word
        char_idx = [lsp_char - 1, line.length - 1].min
        return '' if char_idx < 0

        start = char_idx
        start -= 1 while start >= 0 && line[start] =~ /[A-Za-z0-9_]/
        line[(start + 1)..char_idx] || ''
      end

      def token_to_range(token)
        end_line, end_character = token_end_position(token)
        start_line = token.line - 1
        start_char = encode_char_for_client(start_line, token.column - 1)
        end_char = encode_char_for_client(end_line, end_character)

        {
          start: { line: start_line, character: start_char },
          end:   { line: end_line, character: end_char }
        }
      end

      def token_end_position(token)
        segments = token.lexeme.split("\n", -1)
        if segments.length == 1
          [token.line - 1, token.column - 1 + segments.first.length]
        else
          [token.line - 1 + segments.length - 1, segments.last.length]
        end
      end

      def encode_char_for_client(lsp_line, internal_char)
        return internal_char if @position_encoding == 'utf-16'

        internal_char
      end

      def decode_client_char(uri, lsp_line, client_char)
        return client_char if @position_encoding == 'utf-16'

        content = @workspace.get_content(uri)
        return client_char unless content

        lines = content.split("\n", -1)
        line_text = lines[lsp_line]
        return client_char unless line_text

        if @position_encoding == 'utf-8'
          utf8_to_utf16_char(line_text, client_char)
        elsif @position_encoding == 'utf-32'
          utf32_to_utf16_char(line_text, client_char)
        else
          client_char
        end
      end

      def utf8_to_utf16_char(line_text, utf8_offset)
        bytes_seen = 0
        utf16_count = 0
        line_text.each_char do |ch|
          break if bytes_seen >= utf8_offset
          bytes_seen += ch.bytesize
          utf16_count += ch.ord > 0xFFFF ? 2 : 1
        end
        utf16_count
      end

      def utf32_to_utf16_char(line_text, utf32_offset)
        utf16_count = 0
        line_text.each_char.with_index do |ch, idx|
          break if idx >= utf32_offset
          utf16_count += ch.ord > 0xFFFF ? 2 : 1
        end
        utf16_count
      end

      def diagnostics_fingerprint(content, diagnostics)
        [content, diagnostics].hash.to_s(16)
      end

      def next_diagnostic_result_id(uri, fingerprint)
        "#{uri}:#{fingerprint}"
      end

      def path_to_uri(path)
        escaped_path = path.split('/').map { |seg| CGI.escape(seg).gsub('+', '%20') }.join('/')
        "file://#{escaped_path}"
      end

      def collect_call_argument_starts(tokens, lparen_index)
        starts = []
        depth = 1
        j = lparen_index + 1

        first = next_non_trivia_token(tokens, j)
        starts << first if first && first.type != :rparen

        while j < tokens.length
          tok = tokens[j]
          case tok.type
          when :lparen
            depth += 1
          when :rparen
            depth -= 1
            return [starts, j] if depth.zero?
          when :comma
            if depth == 1
              next_tok = next_non_trivia_token(tokens, j + 1)
              starts << next_tok if next_tok && next_tok.type != :rparen
            end
          end
          j += 1
        end

        [starts, nil]
      end

      def self_describing_argument_expression?(tokens, arg_tok)
        arg_index = tokens.index(arg_tok)
        return false unless arg_index

        simple_identifier_like_argument_expression?(tokens, arg_index)
      end

      def simple_identifier_like_argument_expression?(tokens, start_index)
        saw_identifier = false
        expect_identifier = true
        i = start_index

        while i < tokens.length
          tok = tokens[i]
          break if [:comma, :rparen].include?(tok.type)
          return false if [:newline, :indent, :dedent].include?(tok.type)

          if expect_identifier
            return false unless tok.type == :identifier

            saw_identifier = true
            expect_identifier = false
          else
            return false unless tok.type == :dot

            expect_identifier = true
          end

          i += 1
        end

        saw_identifier && !expect_identifier
      end

      def next_non_trivia_token(tokens, index)
        i = index
        while i < tokens.length
          tok = tokens[i]
          return tok unless [:newline, :indent, :dedent].include?(tok.type)
          i += 1
        end
        nil
      end

      def position_in_range?(line, char, start_line, start_char, end_line, end_char)
        after_start = (line > start_line) || (line == start_line && char >= start_char)
        before_end = (line < end_line) || (line == end_line && char <= end_char)
        after_start && before_end
      end

      def show_message(type, message)
        @protocol.write_notification("window/showMessage", {
          type: MESSAGE_TYPES[type] || type,
          message: message,
        })
      end

      def log_message(type, message)
        @protocol.write_notification("window/logMessage", {
          type: MESSAGE_TYPES[type] || type,
          message: message,
        })
      end

      def show_message_request(type, message, actions:, &callback)
        if @protocol.respond_to?(:send_request)
          @protocol.send_request('window/showMessageRequest', {
            type: MESSAGE_TYPES[type] || type,
            message: message,
            actions: actions.map { |title| { title: title } }
          }) do |result, error|
            if error
              callback.call(nil)
            elsif result.is_a?(Hash) && result['title']
              callback.call(result['title'])
            else
              callback.call(nil)
            end
          end
        else
          Protocol.send_request('window/showMessageRequest', {
            type: MESSAGE_TYPES[type] || type,
            message: message,
            actions: actions.map { |title| { title: title } }
          }) do |result, error|
            if error
              callback.call(nil)
            elsif result.is_a?(Hash) && result['title']
              callback.call(result['title'])
            else
              callback.call(nil)
            end
          end
        end
      end

      MESSAGE_TYPES = {
        error:   1,
        warning: 2,
        info:    3,
        log:     4,
      }.freeze
      end
    end
  end
end
