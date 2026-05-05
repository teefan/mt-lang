# frozen_string_literal: true

require 'cgi/escape'
require 'digest'
require 'pathname'
require 'set'
require 'thread'
require 'uri'

module MilkTea
  module LSP
    # Main LSP server — JSON-RPC 2.0 message loop with full MVP feature set.
    #
    # Enhancements implemented:
    #   1. Hover         — real type signature from semantic analysis
    #   2. Goto Def      — token-based definition site navigation
    #   3. Incremental   — textDocumentSync: 2 with range-based edits
    #   4. Multi-file    — workspace indexing via workspace/symbol
    #   5. Completion    — function/type/value completions from analysis
    class Server
      SEMANTIC_TOKEN_TYPES = %w[
        namespace type class enum interface struct typeParameter parameter variable property enumMember event
        function method macro keyword modifier comment string number regexp operator decorator
      ].freeze
      SEMANTIC_TOKEN_MODIFIERS = %w[
        declaration definition readonly static deprecated abstract async modification documentation defaultLibrary
      ].freeze

      KEYWORD_TOKEN_TYPES = Token::KEYWORDS.values.to_set.freeze
      DEFAULT_LIBRARY_TYPE_NAMES = Types::BUILTIN_TYPE_NAMES.to_set.freeze
      BUILTIN_FUNCTION_NAMES = %w[ref_of const_ptr_of ptr_of read panic ok err cast reinterpret array span zero range].to_set.freeze
      OPERATOR_TOKEN_TYPES = %i[
        amp colon comma caret dot lparen rparen pipe lbracket rbracket question
        equal plus minus star slash percent less greater tilde
        arrow shift_left shift_right plus_equal minus_equal star_equal slash_equal percent_equal
        amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
        equal_equal bang_equal less_equal greater_equal ellipsis
      ].to_set.freeze
      DIAGNOSTICS_WORKER_COUNT = Integer(ENV.fetch('MILK_TEA_LSP_DIAGNOSTICS_WORKERS', '2')).clamp(1, 8)

      def self.semantic_tokens_for_path(path, module_roots: nil)
        expanded_path = File.expand_path(path)
        roots = module_roots || MilkTea::ModuleRoots.roots_for_path(expanded_path)
        source = File.read(expanded_path)
        tokens = MilkTea::Lexer.lex(source, path: expanded_path)
        analysis = MilkTea::ModuleLoader.new(module_roots: roots).check_file(expanded_path)

        helper = allocate
        entries = helper.send(:build_semantic_token_entries, tokens, analysis)
        data = helper.send(:encode_semantic_tokens, entries)

        {
          path: expanded_path,
          moduleName: analysis.module_name,
          legend: {
            tokenTypes: SEMANTIC_TOKEN_TYPES,
            tokenModifiers: SEMANTIC_TOKEN_MODIFIERS,
          },
          data: data,
          entries: entries.map do |entry|
            {
              line: entry[:line],
              startChar: entry[:start_char],
              length: entry[:length],
              tokenType: entry[:type].to_s,
              modifiers: entry[:modifiers].map(&:to_s),
            }
          end,
        }
      end

      def initialize
        @workspace = Workspace.new
        @format_mode = :tidy
        @handlers = {}
        @diagnostic_report_cache = {}
        @semantic_tokens_cache = {}
        @fixall_cache = {}
        @definition_file_token_cache = {}
        @diagnostics_perf = {
          scheduled: 0,
          skipped_unchanged: 0,
          cancelled: 0,
          dequeued: 0,
          published: 0,
          dropped_stale: 0,
          requeued: 0,
          queue_peak: 0,
        }
        @diagnostics_mutex = Mutex.new
        @diagnostics_pending = {}
        @diagnostics_enqueued = Set.new
        @diagnostics_generation = Hash.new(0)
        @diagnostics_last_scheduled_hash = {}
        @diagnostics_queue = Queue.new
        @diagnostics_workers = []
        register_handlers
        start_diagnostics_workers
      end

      def run
        if perf_logging?
          mode = perf_verbose? ? 'verbose' : 'threshold'
          warn "[LSP perf] enabled mode=#{mode} threshold_ms=#{PERF_LOG_THRESHOLD_MS}"
        end

        loop do
          message = Protocol.read_message
          break if message.nil?

          process_message(message)
        end
      rescue StandardError => e
        warn "Server error: #{e.message}"
        raise
      end

      private

      # ── Handler registration ─────────────────────────────────────────────────

      def register_handlers
        # Lifecycle
        @handlers['initialize']  = method(:handle_initialize)
        @handlers['initialized'] = method(:handle_initialized)
        @handlers['shutdown']    = method(:handle_shutdown)
        @handlers['exit']        = method(:handle_exit)

        # Text document sync
        @handlers['textDocument/didOpen']   = method(:handle_did_open)
        @handlers['textDocument/didChange'] = method(:handle_did_change)
        @handlers['textDocument/didClose']  = method(:handle_did_close)
        @handlers['textDocument/didSave']   = method(:handle_did_save)

        # IDE features
        @handlers['textDocument/hover']             = method(:handle_hover)
        @handlers['textDocument/definition']        = method(:handle_definition)
        @handlers['textDocument/declaration']       = method(:handle_declaration)
        @handlers['textDocument/typeDefinition']    = method(:handle_type_definition)
        @handlers['textDocument/references']        = method(:handle_references)
        @handlers['textDocument/documentLink']      = method(:handle_document_link)
        @handlers['textDocument/documentHighlight'] = method(:handle_document_highlight)
        @handlers['textDocument/documentSymbol']    = method(:handle_document_symbols)
        @handlers['textDocument/formatting']        = method(:handle_formatting)
        @handlers['textDocument/rangeFormatting']   = method(:handle_range_formatting)
        @handlers['textDocument/completion']        = method(:handle_completion)
        @handlers['textDocument/codeAction']        = method(:handle_code_action)
        @handlers['textDocument/inlayHint']         = method(:handle_inlay_hint)
        @handlers['textDocument/semanticTokens/full'] = method(:handle_semantic_tokens_full)
        @handlers['textDocument/diagnostic']         = method(:handle_document_diagnostic)
        @handlers['textDocument/signatureHelp']     = method(:handle_signature_help)
        @handlers['textDocument/prepareRename']     = method(:handle_prepare_rename)
        @handlers['textDocument/rename']            = method(:handle_rename)

        # Workspace
        @handlers['workspace/symbol'] = method(:handle_workspace_symbol)
        @handlers['workspace/didChangeConfiguration'] = method(:handle_did_change_configuration)
        @handlers['workspace/didChangeWatchedFiles'] = method(:handle_did_change_watched_files)
      end

      # ── Message dispatch ─────────────────────────────────────────────────────

      def process_message(message)
        method_name = message['method']
        params = message['params'] || {}
        id     = message['id']

        if message.key?('id')
          handle_request(method_name, params, id)
        else
          handle_notification(method_name, params)
        end
      rescue StandardError => e
        warn "Error processing message: #{e.message}"
        Protocol.write_error(id, -32_603, 'Internal server error') if id
      end

      def handle_request(method_name, params, id)
        handler = @handlers[method_name]
        if handler.nil?
          Protocol.write_error(id, -32_601, 'Method not found')
          return
        end

        begin
          @current_request_id = id
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = handler.call(params)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          if perf_logging? && (perf_verbose? || elapsed_ms > PERF_LOG_THRESHOLD_MS)
            detail = perf_verbose? ? " #{summarize_lsp_params(method_name, params)}" : ""
            warn "[LSP perf] req #{method_name} #{elapsed_ms}ms id=#{id}#{detail}"
          end
          Protocol.write_response(id, result)
        rescue StandardError => e
          warn "Error in handler for #{method_name}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          Protocol.write_error(id, -32_603, "Internal error: #{e.message}")
        ensure
          @current_request_id = nil
        end
      end

      def handle_notification(method_name, params)
        handler = @handlers[method_name]
        return unless handler

        begin
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          handler.call(params)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          if perf_logging? && (perf_verbose? || elapsed_ms > PERF_LOG_THRESHOLD_MS)
            detail = perf_verbose? ? " #{summarize_lsp_params(method_name, params)}" : ""
            warn "[LSP perf] ntf #{method_name} #{elapsed_ms}ms#{detail}"
          end
        rescue StandardError => e
          warn "Error in notification handler for #{method_name}: #{e.message}"
        end
      end

      # Log every request regardless of threshold when MILK_TEA_LSP_PERF=verbose.
      # Log only requests exceeding PERF_LOG_THRESHOLD_MS when MILK_TEA_LSP_PERF=1.
      PERF_LOG_THRESHOLD_MS = 1000

      def perf_logging?
        @perf_logging ||= !ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s.empty?
      end

      def perf_verbose?
        @perf_verbose ||= ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s == 'verbose'
      end

      def perf_breakdown_logging?(elapsed_ms)
        perf_logging? && (perf_verbose? || elapsed_ms > PERF_LOG_THRESHOLD_MS)
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

      # Returns true when +uri+ refers to a file outside the workspace root.
      def library_uri?(uri)
        return false unless @root_uri

        file_path = uri_to_path(uri)
        root_path = uri_to_path(@root_uri)
        return false unless file_path && root_path

        !file_path.start_with?(root_path)
      rescue StandardError
        false
      end

      # Skip source.fixAll generation for files where full-file format+lint is
      # too expensive to run on each codeAction request.
      def skip_expensive_source_fix_all?(uri, content)
        !skip_expensive_work_reason(uri, content).nil?
      rescue StandardError
        false
      end

      def skip_expensive_work_reason(uri, content)
        file_path = uri_to_path(uri)
        return 'library-uri' if library_uri?(uri)
        return 'std-path' if file_path&.include?('/std/')

        # Heuristic thresholds to avoid expensive full-file formatter/linter runs.
        return 'large-bytes' if content.bytesize > 200_000
        return 'large-lines' if content.count("\n") > 1200

        nil
      rescue StandardError
        nil
      end

      # ── Lifecycle handlers ───────────────────────────────────────────────────

      def handle_initialize(params)
        @root_uri = params['rootUri']
        apply_configuration_settings(params['initializationOptions'])
        apply_configuration_settings(params['settings'])
        {
          capabilities: {
            textDocumentSync: {
              openClose: true,
              change: 2,
              save: { includeText: false }
            },
            hoverProvider: true,
            definitionProvider: true,
            declarationProvider: true,
            typeDefinitionProvider: true,
            referencesProvider: true,
            documentLinkProvider: {
              resolveProvider: false
            },
            documentHighlightProvider: true,
            documentSymbolProvider: true,
            documentFormattingProvider: true,
            documentRangeFormattingProvider: true,
            signatureHelpProvider: {
              triggerCharacters: ['(', ','],
              retriggerCharacters: [',']
            },
            codeActionProvider: {
              codeActionKinds: ['quickFix', 'source.fixAll']
            },
            inlayHintProvider: true,
            semanticTokensProvider: {
              legend: {
                tokenTypes: SEMANTIC_TOKEN_TYPES,
                tokenModifiers: SEMANTIC_TOKEN_MODIFIERS
              },
              full: true,
              range: false
            },
            completionProvider: {
              triggerCharacters: ['.', '(', ' '],
              resolveProvider: false
            },
            renameProvider: { prepareProvider: true },
            workspaceSymbolProvider: true
          }
        }
      end

      def handle_initialized(_params)
        # Enhancement 4: index all .mt files in the workspace root
        @workspace.index_workspace(@root_uri) if @root_uri
        nil
      end

      def handle_did_change_configuration(params)
        apply_configuration_settings(params['settings'])
        nil
      end

      def handle_shutdown(_params)
        stop_diagnostics_workers
        @workspace.shutdown
        nil
      end

      def handle_exit(_params)
        stop_diagnostics_workers
        @workspace.shutdown
        exit(0)
      end

      # ── Text document sync ───────────────────────────────────────────────────

      def handle_did_open(params)
        uri     = params['textDocument']['uri']
        content = params['textDocument']['text']
        @workspace.open_document(uri, content)
        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
        schedule_diagnostics(uri)
        nil
      end

      def handle_did_change(params)
        uri     = params['textDocument']['uri']
        changes = params['contentChanges'] || []

        # Enhancement 3: apply incremental edits in sequence
        changes.each do |change|
          if change['range']
            @workspace.apply_incremental_change(uri, change)
          else
            # Full-document replace (sync mode 1 fallback)
            @workspace.update_document(uri, change['text'] || '')
          end
        end

        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
        schedule_diagnostics(uri)
        nil
      end

      def handle_did_close(params)
        uri = params['textDocument']['uri']
        cancel_diagnostics(uri)
        @workspace.close_document(uri)
        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
        Protocol.write_notification('textDocument/publishDiagnostics', {
          uri: uri,
          diagnostics: []
        })
        nil
      end

      def handle_did_save(params)
        uri = params.dig('textDocument', 'uri')
        return nil unless uri

        text = params['text']
        @workspace.update_document(uri, text) if text
        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
        schedule_diagnostics(uri)
        nil
      end

      # ── Semantic Tokens ─────────────────────────────────────────────────────

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

        analysis_start = monotonic_time
        analysis_skip_reason = semantic_tokens_analysis_skip_reason(uri, content, for_lsp: true)
        analysis = analysis_skip_reason.nil? ? @workspace.get_analysis(uri) : nil
        analysis_ms = elapsed_ms(analysis_start)

        build_start = monotonic_time
        semantic_entries = build_semantic_token_entries(tokens, analysis)
        build_ms = elapsed_ms(build_start)

        encode_start = monotonic_time
        data = encode_semantic_tokens(semantic_entries)
        encode_ms = elapsed_ms(encode_start)

        @semantic_tokens_cache[uri] = { content_hash: cache_key, data: data }

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        analysis_detail = analysis_skip_reason ? "off(#{analysis_skip_reason})" : 'on'
        log_perf_breakdown('textDocument/semanticTokens/full', elapsed,
                           "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} cache=miss tokens=#{tokens.length} entries=#{semantic_entries.length} data_len=#{data.length} analysis=#{analysis_detail} stages_ms=tokens:#{tokens_ms},analysis:#{analysis_ms},build:#{build_ms},encode:#{encode_ms}")

        { data: data }
      rescue StandardError => e
        warn "Error in semanticTokens/full handler: #{e.message}"
        { data: [] }
      end

      # ── Enhancement 1: Hover — real type signatures ──────────────────────────

      def handle_hover(params)
        uri       = params['textDocument']['uri']
        lsp_line  = params['position']['line']
        lsp_char  = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        info = resolve_hover_info(uri, lsp_line, lsp_char, token: token)
        return nil unless info

        {
          contents: {
            kind: 'markdown',
            value: render_hover_markdown(info)
          },
          range: token_to_range(token)
        }
      rescue StandardError => e
        warn "Error in hover handler: #{e.message}"
        nil
      end

      # Enhancement 2: Goto Definition ──────────────────────────────────────────

      def handle_definition(params)
        location = resolve_definition_location(params)
        location
      rescue StandardError => e
        warn "Error in definition handler: #{e.message}"
        nil
      end

      def handle_declaration(params)
        location = resolve_definition_location(params)
        location
      rescue StandardError => e
        warn "Error in declaration handler: #{e.message}"
        nil
      end

      def handle_type_definition(params)
        location = resolve_definition_location(params)
        location
      rescue StandardError => e
        warn "Error in typeDefinition handler: #{e.message}"
        nil
      end

      # ── References ──────────────────────────────────────────────────────────

      def handle_references(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return [] unless token&.type == :identifier

        refs = @workspace.find_all_references(token.lexeme)
        return refs unless params.dig('context', 'includeDeclaration') == false

        found = @workspace.find_definition_token_global(token.lexeme, preferred_uri: uri)
        return refs unless found

        def_uri = found[:uri]
        def_line = found[:token].line - 1
        def_char = found[:token].column - 1
        refs.reject do |r|
          r[:uri] == def_uri &&
            r[:range][:start][:line] == def_line &&
            r[:range][:start][:character] == def_char
        end
      rescue StandardError => e
        warn "Error in references handler: #{e.message}"
        []
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

      # ── Document Highlight ───────────────────────────────────────────────────

      def handle_document_highlight(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return [] unless token&.type == :identifier

        toks = @workspace.get_tokens(uri) || []
        toks.select { |t| t.type == :identifier && t.lexeme == token.lexeme }
            .map    { |t| { range: token_to_range(t), kind: 1 } }
      rescue StandardError => e
        warn "Error in documentHighlight handler: #{e.message}"
        []
      end

      # ── Signature Help ───────────────────────────────────────────────────────

      def handle_signature_help(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        ctx = @workspace.find_call_context(uri, lsp_line, lsp_char)
        return nil unless ctx

        analysis = @workspace.get_analysis(uri)
        return nil unless analysis

        binding = analysis.functions[ctx[:name]]
        return nil unless binding

        params_list = binding.type.params
        params_str  = format_params(params_list)
        label       = "#{ctx[:name]}(#{params_str}) -> #{binding.type.return_type}"
        parameters  = params_list.map { |p| { label: "#{p.name}: #{p.type}" } }

        {
          signatures:      [{ label: label, parameters: parameters }],
          activeSignature: 0,
          activeParameter: ctx[:active_parameter]
        }
      rescue StandardError => e
        warn "Error in signatureHelp handler: #{e.message}"
        nil
      end

      # ── Prepare Rename / Rename ──────────────────────────────────────────────

      def handle_prepare_rename(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        { range: token_to_range(token), placeholder: token.lexeme }
      rescue StandardError => e
        warn "Error in prepareRename handler: #{e.message}"
        nil
      end

      def handle_rename(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        new_name = params['newName'].to_s

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        refs = @workspace.find_all_references(token.lexeme)
        changes = {}
        refs.each do |ref|
          ref_uri = ref[:uri]
          changes[ref_uri] ||= []
          changes[ref_uri] << { range: ref[:range], newText: new_name }
        end

        { changes: changes }
      rescue StandardError => e
        warn "Error in rename handler: #{e.message}"
        nil
      end

      # ── Document symbols (position-accurate, token-based) ───────────────────

      def handle_document_symbols(params)
        uri     = params['textDocument']['uri']
        symbols = @workspace.get_symbols(uri)
        symbols.map { |sym| format_symbol(sym, uri) }
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      end

      # ── Formatting ───────────────────────────────────────────────────────────

      def handle_formatting(params)
        uri     = params['textDocument']['uri']
        content = @workspace.get_content(uri)

        formatted = Formatter.format_source(content, mode: @format_mode)
        line_count = content.count("\n")

        [
          {
            range: {
              start: { line: 0, character: 0 },
              end:   { line: line_count + 1, character: 0 }
            },
            newText: formatted
          }
        ]
      rescue StandardError => e
        warn "Error in formatting handler: #{e.message}"
        []
      end

      def handle_range_formatting(params)
        uri = params['textDocument']['uri']
        content = @workspace.get_content(uri)
        range = params['range'] || {}
        start_pos = range['start'] || { 'line' => 0, 'character' => 0 }
        end_pos = range['end'] || { 'line' => 0, 'character' => 0 }

        start_off = @workspace.position_to_offset(uri, start_pos['line'], start_pos['character'])
        end_off = @workspace.position_to_offset(uri, end_pos['line'], end_pos['character'])
        return [] if end_off < start_off

        segment = content.byteslice(start_off...end_off).to_s
        formatted_segment = Formatter.format_source(segment, mode: @format_mode)

        [
          {
            range: {
              start: { line: start_pos['line'], character: start_pos['character'] },
              end: { line: end_pos['line'], character: end_pos['character'] }
            },
            newText: formatted_segment
          }
        ]
      rescue StandardError => e
        warn "Error in rangeFormatting handler: #{e.message}"
        []
      end

      def apply_configuration_settings(settings)
        mode = formatter_mode_from_settings(settings)
        @format_mode = mode if mode
      end

      def formatter_mode_from_settings(settings)
        return nil unless settings.is_a?(Hash)

        mode =
          settings.dig('milkTea', 'format', 'mode') ||
          settings.dig('milk_tea', 'format', 'mode') ||
          settings.dig('format', 'mode')
        return nil unless mode

        normalized = mode.to_s.strip.downcase.to_sym
        return normalized if Formatter::MODES.include?(normalized)

        nil
      end

      def handle_code_action(params)
        uri    = params.dig('textDocument', 'uri')
        return [] unless uri

        total_start = monotonic_time
        content = @workspace.get_content(uri)
        return [] unless content

        only_kinds = params.dig('context', 'only')
        want_quickfix  = only_kinds.nil? || only_kinds.any? { |k| k == 'quickFix' || k.start_with?('quickFix.') }
        want_fixall    = !only_kinds.nil? && only_kinds.any? { |k| k == 'source.fixAll' || k == 'source' || k.start_with?('source.') }

        actions = []
        lines = content.lines
        requested_diagnostics = params.dig('context', 'diagnostics') || []

        quickfix_start = monotonic_time

        # ── Per-diagnostic quickfix actions ──────────────────────────────────
        if want_quickfix
        requested_diagnostics.each do |diag|
          code = diag['code']
          message = diag['message'].to_s
          diag_line = diag.dig('range', 'start', 'line').to_i + 1  # 1-based
          diag_start_char = diag.dig('range', 'start', 'character').to_i
          diag_end_char = diag.dig('range', 'end', 'character').to_i
          source_line = lines[diag_line - 1].to_s

          if message.start_with?('cannot assign ') && !source_line.empty?
            expected_type = message[/\bexpected\s+(.+)\z/, 1]&.strip
            equal_index = source_line.index('=')
            if expected_type && !expected_type.empty? && equal_index
              rhs = source_line[(equal_index + 1)..]&.strip
              if rhs && !rhs.empty? && !rhs.start_with?("#{expected_type}<-")
                indent = source_line[/\A\s*/] || ''
                lhs = source_line[0..equal_index].rstrip
                simple_value = rhs.match?(/\A(?:[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?|0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+)\z/)
                casted_rhs = simple_value ? "#{expected_type}<-#{rhs}" : "#{expected_type}<-(#{rhs})"
                new_line = "#{indent}#{lhs} #{casted_rhs}\n"
                actions << {
                  title: "Cast expression to #{expected_type}",
                  kind: 'quickFix',
                  diagnostics: [diag],
                  edit: {
                    changes: {
                      uri => [{
                        range: {
                          start: { line: diag_line - 1, character: 0 },
                          end:   { line: diag_line,     character: 0 }
                        },
                        newText: new_line
                      }]
                    }
                  }
                }
              end
            end
          end

          case code
          when 'prefer-let'
            # Replace `var` with `let` on the declaration line
            source_line = lines[diag_line - 1].to_s
            next unless source_line.match?(/\bvar\b/)

            new_line = source_line.sub(/\bvar\b/, 'let')
            actions << {
              title: "Replace 'var' with 'let'",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: diag_line - 1, character: 0 },
                      end:   { line: diag_line,     character: 0 }
                    },
                    newText: new_line
                  }]
                }
              }
            }

          when 'redundant-else'
            # Remove the `else:` line above and dedent the body.
            # Supports diagnostics anchored either on `else:` or the first body line.
            diag_idx = diag_line - 1
            next if diag_idx.negative?

            if lines[diag_idx]&.match?(/\A\s*else:\s*\z/)
              else_idx = diag_idx
              first_body_idx = else_idx + 1
            else
              first_body_idx = diag_idx
              next if first_body_idx < 1
              else_idx = (0...first_body_idx).to_a.reverse.find do |i|
                lines[i]&.match?(/\A\s*else:\s*\z/)
              end
            end
            next unless else_idx
            next if first_body_idx >= lines.length

            else_indent  = lines[else_idx].match(/\A(\s*)/)[1]
            body_indent  = else_indent + '    '

            body_end_idx = first_body_idx
            (first_body_idx...lines.length).each do |i|
              l = lines[i]
              if l.chomp.empty? || l.start_with?(body_indent)
                body_end_idx = i
              else
                break
              end
            end

            # Build the replacement: dedented body lines replacing `else:\nbody`
            new_body = lines[first_body_idx..body_end_idx].map { |l| l.sub(/\A    /, '') }.join
            actions << {
              title: "Remove redundant else",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: else_idx,        character: 0 },
                      end:   { line: body_end_idx + 1, character: 0 }
                    },
                    newText: new_body
                  }]
                }
              }
            }

          when 'shadow'
            # Offer to rename to _ prefix; editor will invoke textDocument/rename.
            # This action just annotates — the actual rename is a client-side refactor.
            actions << {
              title: "Add '_' prefix to suppress shadow warning",
              kind: 'quickFix',
              diagnostics: [diag]
            }

          when 'unused-param'
            next if source_line.empty?

            token = source_line[diag_start_char...diag_end_char].to_s
            token = token.strip
            next if token.empty?
            next if token.start_with?('_')

            replacement = "_#{token.gsub(/\A_+/, '')}"
            actions << {
              title: "Rename parameter '#{token}' to '#{replacement}'",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: diag_line - 1, character: diag_start_char },
                      end:   { line: diag_line - 1, character: diag_end_char }
                    },
                    newText: replacement
                  }]
                }
              }
            }

          when 'dead-assignment'
            next if source_line.empty?

            # Linter guarantees this write is overwritten before any read,
            # so dropping the statement is semantics-preserving.
            actions << {
              title: 'Remove dead assignment',
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: diag_line - 1, character: 0 },
                      end:   { line: diag_line,     character: 0 }
                    },
                    newText: ''
                  }]
                }
              }
            }

          else
            next if source_line.empty?

            # Wrap unsafe-required pointer casts into a local unsafe block.
            if message == 'pointer cast requires unsafe' || message == 'ref to pointer cast requires unsafe'
              next if source_line.match?(/\A\s*unsafe:\s*\z/)

              indent = source_line[/\A\s*/] || ''
              body = source_line.sub(/\A\s*/, '').rstrip
              next if body.empty?

              wrapped = "#{indent}unsafe:\n#{indent}    #{body}\n"
              actions << {
                title: 'Wrap statement in unsafe block',
                kind: 'quickFix',
                diagnostics: [diag],
                edit: {
                  changes: {
                    uri => [{
                      range: {
                        start: { line: diag_line - 1, character: 0 },
                        end:   { line: diag_line,     character: 0 }
                      },
                      newText: wrapped
                    }]
                  }
                }
              }
            end
          end
        end
        end # want_quickfix
        quickfix_ms = elapsed_ms(quickfix_start)

        # ── source.fixAll: apply all auto-fixes at once ────────────────────
        # Skip for files outside the workspace root (library/std files) since
        # formatting and linting a large stdlib file costs seconds per call.
        fixall_ms = 0.0
        fixall_skipped_reason = want_fixall ? skip_expensive_work_reason(uri, content) : 'not-requested'
        unless fixall_skipped_reason
          fixall_start = monotonic_time
          begin
            content_hash = content.hash
            cached_fixall = @fixall_cache[uri]
            if cached_fixall && cached_fixall[:content_hash] == content_hash
              fixed = cached_fixall[:fixed]
            else
              formatted = begin
                Formatter.format_source(content, mode: :safe)
              rescue StandardError
                content
              end
              fixed = begin
                Linter.fix_source(formatted, path: uri)
              rescue StandardError
                formatted
              end
              @fixall_cache[uri] = { content_hash: content_hash, fixed: fixed }
            end
            line_count = content.count("\n")
            actions << {
              title: 'Apply all auto-fixes',
              kind: 'source.fixAll',
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: 0, character: 0 },
                      end:   { line: line_count + 1, character: 0 }
                    },
                    newText: fixed
                  }]
                }
              }
            }
          rescue StandardError => e
            warn "Error building source.fixAll action: #{e.message}"
          end
          fixall_ms = elapsed_ms(fixall_start)
        end

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        fixall_detail = fixall_skipped_reason ? "skipped(#{fixall_skipped_reason})" : "generated(ms=#{fixall_ms})"
        log_perf_breakdown('textDocument/codeAction', elapsed,
                           "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} diagnostics=#{requested_diagnostics.length} actions=#{actions.length} fixAll=#{fixall_detail} stages_ms=quickfix:#{quickfix_ms},fixAll:#{fixall_ms}")

        actions
      rescue StandardError => e
        warn "Error in codeAction handler: #{e.message}"
        []
      end

      def semantic_tokens_use_analysis?(uri, content)
        return false if semantic_tokens_analysis_skip_reason(uri, content)

        true
      rescue StandardError
        true
      end

      def semantic_tokens_analysis_skip_reason(uri, content, for_lsp: false)
        # Skip analysis for URIs outside the workspace (e.g. vscode-internal or gem paths).
        # This includes the system MilkTea stdlib and gem code.
        return 'library-uri' if library_uri?(uri)

        nil
      rescue StandardError
        nil
      end

      def handle_document_diagnostic(params)
        uri = params.dig('textDocument', 'uri')
        return { kind: 'full', items: [] } unless uri

        content = @workspace.get_content(uri)
        diagnostics = @workspace.collect_diagnostics(uri)
        fingerprint = diagnostics_fingerprint(content, diagnostics)
        previous_result_id = params['previousResultId']
        cached = @diagnostic_report_cache[uri]

        if cached && cached[:result_id] == previous_result_id && cached[:fingerprint] == fingerprint
          return {
            kind: 'unchanged',
            resultId: cached[:result_id]
          }
        end

        result_id = next_diagnostic_result_id(uri, fingerprint)
        @diagnostic_report_cache[uri] = {
          result_id: result_id,
          fingerprint: fingerprint
        }

        {
          kind: 'full',
          resultId: result_id,
          items: diagnostics
        }
      rescue StandardError => e
        warn "Error in documentDiagnostic handler: #{e.message}"
        { kind: 'full', items: [] }
      end

      def handle_inlay_hint(params)
        uri = params.dig('textDocument', 'uri')
        range = params['range'] || {}
        start_line = range.dig('start', 'line') || 0
        start_char = range.dig('start', 'character') || 0
        end_line = range.dig('end', 'line') || 0
        end_char = range.dig('end', 'character') || 0

        content = @workspace.get_content(uri)
        return [] if content && skip_expensive_work_reason(uri, content)

        analysis = @workspace.get_analysis(uri)
        tokens = @workspace.get_tokens(uri)
        return [] unless analysis && tokens

        hints = []
        i = 0
        while i < tokens.length - 1
          callee = tokens[i]
          next_tok = tokens[i + 1]

          # Skip function definitions — `def foo(` has the same identifier+lparen
          # shape as a call site but must not get parameter-name inlay hints.
          prev_tok = i > 0 ? tokens[i - 1] : nil

          # Also support module-qualified call sites (`mod.fn(...)`).
          # Ignore identifiers immediately after `.` to avoid treating member names
          # as unqualified local calls.
          if callee.type == :identifier && prev_tok&.type != :def && prev_tok&.type != :dot
            binding = nil
            lparen_index = nil

            if next_tok&.type == :lparen
              binding = analysis.functions[callee.lexeme]
              lparen_index = i + 1
            elsif next_tok&.type == :dot
              member = tokens[i + 2]
              member_lparen = tokens[i + 3]
              if member&.type == :identifier && member_lparen&.type == :lparen
                module_binding = analysis.imports[callee.lexeme]
                binding = module_binding&.functions&.[](member.lexeme)
                lparen_index = i + 3
              end
            end

            if binding && lparen_index
              arg_starts, closing_index = collect_call_argument_starts(tokens, lparen_index)
              params_list = binding.type.params

              arg_starts.each_with_index do |arg_tok, index|
                break if index >= params_list.length
                next unless position_in_range?(arg_tok.line - 1, arg_tok.column - 1, start_line, start_char, end_line, end_char)
                # Suppress hint when the argument is a bare identifier whose name
                # already matches the parameter — `foo(x: x)` hints are just noise.
                param_name = params_list[index].name
                next if arg_tok.type == :identifier && arg_tok.lexeme == param_name

                hints << {
                  position: { line: arg_tok.line - 1, character: arg_tok.column - 1 },
                  label: "#{params_list[index].name}: ",
                  kind: 2,
                  paddingRight: true
                }
              end

              i = closing_index if closing_index
            end
          end

          i += 1
        end

        hints
      rescue StandardError => e
        warn "Error in inlayHint handler: #{e.message}"
        []
      end

      # ── Enhancement 6: Completion ────────────────────────────────────────────

      def handle_completion(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        analysis = @workspace.get_analysis(uri)
        return { isIncomplete: false, items: [] } unless analysis

        prefix = current_word_prefix(uri, lsp_line, lsp_char)

        # When user is typing after '.', return module members or method completions.
        dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
        if dot_recv
          # Module member access: rl.init_window, rl.RAYWHITE, etc.
          if (module_binding = analysis.imports[dot_recv])
            items = []
            module_binding.functions.each do |fname, binding|
              next unless prefix.empty? || fname.start_with?(prefix)
              params_str = format_params(binding.type.params)
              items << {
                label:      fname,
                kind:       3,  # Function
                detail:     "def #{fname}(#{params_str}) -> #{binding.type.return_type}",
                insertText: fname,
                sortText:   "0_#{fname}"
              }
            end
            module_binding.values.each do |vname, binding|
              next unless prefix.empty? || vname.start_with?(prefix)
              items << {
                label:      vname,
                kind:       6,  # Variable
                detail:     "#{vname}: #{binding.type}",
                insertText: vname,
                sortText:   "1_#{vname}"
              }
            end
            module_binding.types.each do |tname, _type|
              next unless prefix.empty? || tname.start_with?(prefix)
              items << {
                label:      tname,
                kind:       7,  # Class
                detail:     "type #{tname}",
                insertText: tname,
                sortText:   "2_#{tname}"
              }
            end
            return { isIncomplete: false, items: items }
          end

          # Enum/Flags member access: Color.RED, KeyboardKey.A, etc.
          if (type = analysis.types[dot_recv]).is_a?(Types::EnumBase)
            items = type.members.filter_map do |mname|
              next if !prefix.empty? && !mname.start_with?(prefix)
              {
                label:      mname,
                kind:       20, # EnumMember
                detail:     "#{dot_recv}.#{mname}",
                insertText: mname,
                sortText:   "0_#{mname}"
              }
            end
            return { isIncomplete: false, items: items }
          end

          # Variant arm access: Option.None, Result.Ok, etc.
          if (type = analysis.types[dot_recv]).is_a?(Types::Variant)
            items = type.arm_names.filter_map do |aname|
              next if !prefix.empty? && !aname.start_with?(prefix)
              {
                label:      aname,
                kind:       20, # EnumMember
                detail:     "#{dot_recv}.#{aname}",
                insertText: aname,
                sortText:   "0_#{aname}"
              }
            end
            return { isIncomplete: false, items: items }
          end

          if (receiver_type = resolve_dot_receiver_value_type(analysis, dot_recv, lsp_line + 1, lsp_char + 1))
            items = completion_items_for_value_receiver(analysis, receiver_type, prefix)
            return { isIncomplete: false, items: items } unless items.empty?
          end

          # Method completions on a non-module receiver.
          method_items = []
          analysis.methods.each do |_recv_type, methods|
            methods.each do |mname, binding|
              next unless prefix.empty? || mname.start_with?(prefix)

              params_str = format_params(binding.type.params)
              method_items << {
                label:      mname,
                kind:       2,  # Method
                detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
                insertText: mname,
                sortText:   "0_#{mname}"
              }
            end
          end
          return { isIncomplete: false, items: method_items }
        end

        items = []

        # Functions
        analysis.functions.each do |name, binding|
          next unless prefix.empty? || name.start_with?(prefix)

          params_str = format_params(binding.type.params)
          items << {
            label:        name,
            kind:         3,  # Function
            detail:       "def #{name}(#{params_str}) -> #{binding.type.return_type}",
            insertText:   name,
            sortText:     "0_#{name}"  # Functions first
          }
        end

        # User-defined types
        builtin_names = Sema::BUILTIN_TYPE_NAMES
        analysis.types.each do |name, _type|
          next if builtin_names.include?(name)
          next unless prefix.empty? || name.start_with?(prefix)

          items << {
            label:      name,
            kind:       7,  # Class
            detail:     "type #{name}",
            insertText: name,
            sortText:   "1_#{name}"
          }
        end

        # Top-level values / constants
        analysis.values.each do |name, binding|
          next unless prefix.empty? || name.start_with?(prefix)

          items << {
            label:      name,
            kind:       6,  # Variable
            detail:     "#{name}: #{binding.type}",
            insertText: name,
            sortText:   "2_#{name}"
          }
        end

        { isIncomplete: false, items: items }
      rescue StandardError => e
        warn "Error in completion handler: #{e.message}"
        { isIncomplete: false, items: [] }
      end

      # ── Enhancement 4: Workspace Symbol ─────────────────────────────────────

      def handle_workspace_symbol(params)
        query = (params['query'] || '').downcase

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

      def handle_did_change_watched_files(params)
        changes = params['changes'] || []
        changes.each do |change|
          uri = change['uri']
          type = change['type']
          next unless uri

          @workspace.apply_watched_file_change(uri, type)
        end
        nil
      end

      # ── Diagnostics ──────────────────────────────────────────────────────────

      def schedule_diagnostics(uri)
        content = @workspace.get_content(uri)
        content_digest = Digest::SHA256.hexdigest(content)
        enqueue = false

        @diagnostics_mutex.synchronize do
          if @diagnostics_last_scheduled_hash[uri] == content_digest
            @diagnostics_perf[:skipped_unchanged] += 1 if perf_logging?
            return
          end

          @diagnostics_generation[uri] += 1
          @diagnostics_last_scheduled_hash[uri] = content_digest
          @diagnostics_perf[:scheduled] += 1 if perf_logging?
          @diagnostics_pending[uri] = {
            generation: @diagnostics_generation[uri],
            content: content,
          }

          unless @diagnostics_enqueued.include?(uri)
            @diagnostics_enqueued << uri
            enqueue = true
          end
        end

        if enqueue
          @diagnostics_queue << uri
          if perf_logging?
            @diagnostics_perf[:queue_peak] = [@diagnostics_perf[:queue_peak], @diagnostics_queue.length].max
          end
        end
      end

      def cancel_diagnostics(uri)
        @diagnostics_mutex.synchronize do
          @diagnostics_generation[uri] += 1
          @diagnostics_pending.delete(uri)
          @diagnostics_last_scheduled_hash.delete(uri)
          @diagnostics_perf[:cancelled] += 1 if perf_logging?
        end
      end

      def start_diagnostics_workers
        return if @diagnostics_workers.any?(&:alive?)

        DIAGNOSTICS_WORKER_COUNT.times do |index|
          @diagnostics_workers << Thread.new do
            if Thread.current.respond_to?(:name=)
              Thread.current.name = "mt-lsp-diagnostics-#{index + 1}"
            end

            loop do
              uri = @diagnostics_queue.pop
              break if uri == :__stop__

              process_diagnostics_for_uri(uri)
            end
          rescue StandardError => e
            warn "LSP diagnostics worker error: #{e.message}"
          end
        end
      end

      def stop_diagnostics_workers
        workers = @diagnostics_workers
        return if workers.empty?

        workers.length.times { @diagnostics_queue << :__stop__ }
        workers.each { |worker| worker.join(0.25) }
        @diagnostics_workers = []
      rescue StandardError => e
        warn "LSP diagnostics worker shutdown error: #{e.message}"
      end

      def process_diagnostics_for_uri(uri)
        loop do
          snapshot = nil
          @diagnostics_mutex.synchronize do
            snapshot = @diagnostics_pending.delete(uri)
          end
          break unless snapshot

          @diagnostics_perf[:dequeued] += 1 if perf_logging?

          diagnostics = collect_diagnostics_for_content(uri, snapshot[:content])
          publish = false
          @diagnostics_mutex.synchronize do
            publish = snapshot[:generation] == @diagnostics_generation[uri]
          end

          if publish
            @diagnostics_perf[:published] += 1 if perf_logging?
            Protocol.write_notification('textDocument/publishDiagnostics', {
              uri: uri,
              diagnostics: diagnostics
            })
          elsif perf_logging?
            @diagnostics_perf[:dropped_stale] += 1
          end
        end
      ensure
        requeue = false
        @diagnostics_mutex.synchronize do
          @diagnostics_enqueued.delete(uri)
          if @diagnostics_pending.key?(uri)
            @diagnostics_enqueued << uri
            requeue = true
          end
        end

        if requeue
          @diagnostics_perf[:requeued] += 1 if perf_logging?
          @diagnostics_queue << uri
          if perf_logging?
            @diagnostics_perf[:queue_peak] = [@diagnostics_perf[:queue_peak], @diagnostics_queue.length].max
          end
        end
      end

      def collect_diagnostics_for_content(uri, content)
        Diagnostics.collect(uri, content)
      rescue StandardError => e
        warn "LSP diagnostics error #{uri}: #{e.message}"
        []
      end

      # ── Enhancement 1 helpers: hover type resolution ─────────────────────────

      def resolve_hover_info(uri, lsp_line, lsp_char, token: nil)
        token ||= @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        tokens = @workspace.get_tokens(uri) || []
        token_index = tokens.index(token)
        if token_index
          module_info = module_declaration_info_at(tokens, token_index)
          if module_info
            location = module_definition_location(uri, module_info[:module_name])
            return {
              signature: "module #{module_info[:module_name]}",
              docs: nil,
              source: hover_source_label_from_location(location),
              source_uri: hover_source_uri_from_location(location),
              source_line: hover_source_line_from_location(location),
            }
          end
        end

        if token_index
          import_info = import_path_info_at(tokens, token_index)
          if import_info
            location = module_definition_location(uri, import_info[:module_name])
            return {
              signature: "module #{import_info[:module_name]}",
              docs: nil,
              source: hover_source_label_from_location(location),
              source_uri: hover_source_uri_from_location(location),
              source_line: hover_source_line_from_location(location),
            }
          end
        end

        analysis = @workspace.get_analysis(uri)
        return nil unless analysis

        name = token.lexeme
        signature = nil
        source_location = nil

        if (binding = analysis.functions[name])
          params_str = format_params(binding.type.params)
          signature = "def #{name}(#{params_str}) -> #{binding.type.return_type}"
        elsif analysis.types.key?(name)
          type = analysis.types[name]
          signature = "type #{name} = #{type}"
        elsif (binding = analysis.values[name])
          signature = "#{name}: #{binding.type}"
        elsif (import_binding = analysis.imports[name])
          signature = "module #{import_binding.name}"
          source_location = module_definition_location(uri, import_binding.name)
        else
          dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          if dot_receiver && (module_binding = analysis.imports[dot_receiver])
            if (fn = module_binding.functions[name])
              params_str = format_params(fn.type.params)
              signature = "def #{name}(#{params_str}) -> #{fn.type.return_type}"
            elsif (val = module_binding.values[name])
              signature = "#{name}: #{val.type}"
            elsif module_binding.types.key?(name)
              signature = "type #{name}"
            end

            if signature
              source_location = module_member_definition_location(uri, module_binding.name, name)
              source_location ||= module_definition_location(uri, module_binding.name)
            end
          end

          unless signature
            if (local_type = resolve_local_hover_type(analysis, name, lsp_line + 1, lsp_char + 1))
              signature = "#{name}: #{local_type}"
            end
          end

          unless signature
            local_def = @workspace.find_definition_token(
              uri,
              name,
              before_line: lsp_line + 1,
              before_char: lsp_char + 1,
            )
            signature = "local #{name}" if local_def
          end

          return nil unless signature
        end

        definition_entry = if source_location
                             hover_definition_entry_from_location(source_location)
                           else
                             @workspace.find_definition_token_global(
                               name,
                               preferred_uri: uri,
                               before_line: lsp_line + 1,
                               before_char: lsp_char + 1,
                             )
                           end

        source_uri = hover_source_uri_for_definition(definition_entry) || hover_source_uri_from_location(source_location)
        source_line = hover_source_line_for_definition(definition_entry) || hover_source_line_from_location(source_location)

        {
          signature: signature,
          docs: hover_doc_comment_for_definition(definition_entry),
          source: hover_source_label_for_definition(definition_entry) || hover_source_label_from_location(source_location),
          source_uri: source_uri,
          source_line: source_line,
        }
      end

      def render_hover_markdown(info)
        lines = []
        lines << "```milk-tea"
        lines << info[:signature]
        lines << "```"

        docs = info[:docs].to_s.strip
        unless docs.empty?
          lines << ""
          lines << docs
        end

        source_uri = info[:source_uri]
        source_line = info[:source_line]
        source_label = info[:source].to_s.strip
        unless source_label.empty?
          lines << ""
          if source_uri && source_line
            link_uri = "#{source_uri}#L#{source_line}"
            lines << "Defined at: [#{source_label}](#{link_uri})"
          else
            lines << "Defined at: #{source_label}"
          end
        end

        lines.join("\n")
      end

      def hover_doc_comment_for_definition(definition_entry)
        return nil unless definition_entry

        @workspace.doc_comment_for_definition(definition_entry[:uri], definition_entry[:token])
      end

      def hover_source_label_for_definition(definition_entry)
        return nil unless definition_entry

        hover_source_label(definition_entry[:uri], definition_entry[:token].line)
      end

      def hover_source_uri_for_definition(definition_entry)
        return nil unless definition_entry

        definition_entry[:uri]
      end

      def hover_source_line_for_definition(definition_entry)
        return nil unless definition_entry

        definition_entry[:token].line
      end

      def hover_source_label_from_location(location)
        return nil unless location

        line = location.dig(:range, :start, :line)
        hover_source_label(location[:uri], (line || 0) + 1)
      end

      def hover_source_uri_from_location(location)
        return nil unless location

        location[:uri]
      end

      def hover_source_line_from_location(location)
        return nil unless location

        line = location.dig(:range, :start, :line)
        (line || 0) + 1
      end

      def hover_source_label(uri, line)
        path = uri_to_path(uri)
        return nil unless path

        display = path
        if @root_uri
          root_path = uri_to_path(@root_uri)
          if root_path
            begin
              relative = Pathname.new(path).relative_path_from(Pathname.new(root_path)).to_s
              display = relative unless relative.start_with?('..')
            rescue StandardError
              display = path
            end
          end
        end

        "#{display}:#{line}"
      end

      def hover_definition_entry_from_location(location)
        return nil unless location

        start = location.dig(:range, :start)
        return nil unless start

        token = @workspace.find_token_at(location[:uri], start[:line], start[:character])
        return nil unless token

        { uri: location[:uri], token: token }
      end

      def resolve_definition_location(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        tokens = @workspace.get_tokens(uri) || []
        token_index = tokens.index(token)
        return nil if token_index && module_declaration_info_at(tokens, token_index)

        if token_index && (import_info = import_path_info_at(tokens, token_index))
          return module_definition_location(uri, import_info[:module_name])
        end

        analysis = @workspace.get_analysis(uri)
        if analysis
          if token_index && (member_access = module_member_access_info(tokens, token_index))
            if (import_binding = analysis.imports[member_access[:receiver]])
              module_name = import_binding.name
              member_location = module_member_definition_location(uri, module_name, token.lexeme)
              return member_location if member_location
              return module_definition_location(uri, module_name)
            end
          end

          dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          if dot_receiver && analysis.imports.key?(dot_receiver)
            module_name = analysis.imports.fetch(dot_receiver).name
            return module_member_definition_location(uri, module_name, token.lexeme) || module_definition_location(uri, module_name)
          elsif analysis.imports.key?(token.lexeme)
            module_name = analysis.imports.fetch(token.lexeme).name
            return module_definition_location(uri, module_name)
          end
        end

        found = @workspace.find_definition_token_global(
          token.lexeme,
          preferred_uri: uri,
          before_line: lsp_line + 1,
          before_char: lsp_char + 1,
        )
        return nil unless found

        {
          uri: found[:uri],
          range: token_to_range(found[:token])
        }
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

      def build_semantic_token_entries(tokens, analysis = nil)
        # Precompute line → non-trivia tokens index so non_trivia_tokens_on_line
        # is O(1) per call instead of O(n), turning the overall build from O(n²) to O(n).
        trivia_types = Set[:newline, :indent, :dedent, :eof]
        @tokens_by_line_cache = Hash.new { |h, k| h[k] = [] }
        tokens.each { |t| @tokens_by_line_cache[t.line] << t unless trivia_types.include?(t.type) }

        entries = []

        tokens.each_with_index do |tok, index|
          next if [:newline, :indent, :dedent, :eof].include?(tok.type)

          if tok.type == :fstring
            fstring_interpolation_entries(tok, analysis).each { |e| entries << e }
            next
          end

          semantic_type, modifiers = classify_semantic_token(tokens, index, analysis)
          next unless semantic_type

          entries << {
            line: tok.line - 1,
            start_char: tok.column - 1,
            length: tok.lexeme.length,
            type: semantic_type,
            modifiers: modifiers
          }
        end

        entries.sort_by { |entry| [entry[:line], entry[:start_char]] }
      ensure
        @tokens_by_line_cache = nil
      end

      # Decomposes an fstring token into non-overlapping semantic token entries.
      # Text segments are emitted as :string and interpolation expression segments
      # are emitted semantically. Delimiter punctuation is left to TextMate.
      def fstring_interpolation_entries(fstring_tok, analysis)
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
              sub_tokens = MilkTea::Lexer.new(source).lex
                                        .reject { |t| [:newline, :indent, :dedent, :eof].include?(t.type) }
              sub_tokens.each_with_index do |sub_tok, i|
                sem_type, modifiers = classify_semantic_token(sub_tokens, i, analysis)
                next unless sem_type
                result << {
                  line: fstr_line,
                  start_char: expr_col0 + (sub_tok.column - 1),
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
                  spec_sem_type, spec_modifiers = classify_semantic_token(spec_tokens, i, analysis)
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

      def classify_semantic_token(tokens, index, analysis = nil)
        tok = tokens[index]

        if tok.type == :identifier
          return classify_name_semantic(tok.lexeme, tokens, index, analysis)
        end

        if [:string, :cstring].include?(tok.type)
          return [:string, []]
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

      def classify_name_semantic(name, tokens, index, analysis = nil)
        prev_tok = previous_non_trivia_token(tokens, index)
        next_tok = next_non_trivia_token(tokens, index + 1)

        if (import_info = import_path_info_at(tokens, index, allow_keywords: true))
          modifiers = []
          modifiers << 'declaration' if import_info[:role] == :alias
          return [:namespace, modifiers]
        end

        return [:namespace, []] if module_declaration_path_token?(tokens, index)

        if prev_tok && [:def, :fn, :proc].include?(prev_tok.type)
          return [:function, ['declaration']]
        end

        if prev_tok && [:struct, :union, :enum, :flags, :variant, :type, :opaque].include?(prev_tok.type)
          return [:type, ['declaration']]
        end

        if prev_tok&.type == :const
          return [:variable, ['declaration', 'readonly']]
        end

        if prev_tok && [:let, :var].include?(prev_tok.type)
          return [:variable, ['declaration']]
        end

        if next_tok&.type == :dot && analysis
          return [:type, []] if analysis.types.key?(name)
          return [:namespace, []] if analysis.imports.key?(name)
        end

        if analysis && analysis.types.key?(name) && identifier_in_type_argument_position?(tokens, index)
          return [:type, []]
        end

        return [:enumMember, ['declaration']] if variant_enum_member_declaration?(tokens, index)

        if prev_tok&.type == :dot
          if analysis
            module_binding = imported_module_binding_for_member(tokens, index, analysis)
            if module_binding
              return [:function, []] if module_binding.functions.key?(name)
              return [:type, []] if module_binding.types.key?(name)
              if (value_binding = module_binding.values[name])
                modifiers = []
                modifiers << 'readonly' if value_binding.respond_to?(:mutable) && value_binding.mutable == false
                return [:variable, modifiers]
              end
              return [:namespace, []] if analysis.imports.key?(name)
            end
          end

          return [:enumMember, []] if type_name_member_access?(tokens, index)
          return [:method, []] if next_tok&.type == :lparen
          return [:property, []]
        end

        if next_tok&.type == :lparen
          modifiers = []
          modifiers << 'defaultLibrary' if BUILTIN_FUNCTION_NAMES.include?(name)
          return [:function, modifiers]
        end

        # Specialization syntax that is followed by a call: `cast[T](x)`,
        # `array[T](...)`, etc. Bare `array[T, N]` and `span[T]` in annotations
        # are types, not functions.
        if next_tok&.type == :lbracket && BUILTIN_FUNCTION_NAMES.include?(name) && specialized_call_with_type_args?(tokens, index)
          return [:function, ['defaultLibrary']]
        end

        if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
          return [:type, ['defaultLibrary']]
        end

        if analysis
          return [:type, []] if analysis.types.key?(name)
          return [:namespace, []] if analysis.imports.key?(name)
        end

        [:variable, []]
      end

      def imported_module_binding_for_member(tokens, index, analysis)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return nil unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return nil unless receiver_index

        receiver = tokens[receiver_index]
        return nil unless receiver.type == :identifier

        analysis.imports[receiver.lexeme]
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
        return false unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return false unless rbracket_index

        next_index = next_non_trivia_token_index(tokens, index + 1)
        return false unless next_index

        # Type argument entries should stay inside the current [] pair.
        next_index <= rbracket_index
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

        module_identifiers = module_tokens.select { |line_tok| line_tok.type == :identifier }
        return nil if module_identifiers.empty?

        module_name = module_identifiers.map(&:lexeme).join('.')
        return { module_name: module_name, role: :module_path } if module_identifiers.include?(tok)
        return { module_name: module_name, role: :alias } if alias_token == tok

        nil
      end

      # Returns true if the identifier at `index` is a variant/enum/flags member
      # declared directly in a type body — e.g. `none` or `some(value: T)` inside
      # `variant Option[T]:`. Detects this by finding that the token is the first
      # non-trivia token on its (indented) line and the nearest less-indented line
      # starts with `variant`, `enum`, or `flags`.
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
          return [:variant, :enum, :flags].include?(header_line_toks.first&.type)
        end
        false
      end

      # Returns true if the token at `index` (accessed via `.`) is a member of a
      # type name receiver, e.g. `Option.none`, `Outcome[int, str].ok`.
      def type_name_member_access?(tokens, index)
        dot_index = previous_non_trivia_token_index(tokens, index)
        return false unless dot_index && tokens[dot_index].type == :dot

        receiver_index = previous_non_trivia_token_index(tokens, dot_index)
        return false unless receiver_index

        receiver = tokens[receiver_index]
        if receiver.type == :identifier
          return receiver.lexeme.match?(/\A[A-Z]/)
        end

        if receiver.type == :rbracket
          lbracket_i = matching_opener_index(tokens, receiver_index)
          return false unless lbracket_i

          base_index = previous_non_trivia_token_index(tokens, lbracket_i)
          return false unless base_index

          base = tokens[base_index]
          return base.type == :identifier && base.lexeme.match?(/\A[A-Z]/)
        end

        false
      end

      # Backward version of matching_closer_index: given the index of a closing
      # bracket/paren, find the matching opener by scanning backward.
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

      def module_declaration_path_token?(tokens, index)
        !module_declaration_info_at(tokens, index).nil?
      end

      def module_declaration_info_at(tokens, index)
        tok = tokens[index]
        return nil unless tok&.type == :identifier

        line_tokens = non_trivia_tokens_on_line(tokens, tok.line)
        return nil if line_tokens.empty? || line_tokens.first.type != :module

        path_tokens = line_tokens[1..].to_a.select { |line_tok| line_tok.type == :identifier }
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

        entries.each_with_index do |entry, idx|
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

      def semantic_modifiers_bitset(modifiers)
        bits = 0
        Array(modifiers).each do |modifier|
          idx = SEMANTIC_TOKEN_MODIFIERS.index(modifier.to_s)
          next unless idx

          bits |= (1 << idx)
        end
        bits
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

      def module_path_for_name(current_uri, module_name)
        current_path = uri_to_path(current_uri)
        return nil unless current_path

        module_roots = MilkTea::ModuleRoots.roots_for_path(current_path)
        relative_path = File.join(*module_name.split('.')) + '.mt'
        module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |candidate| File.file?(candidate) }
      end

      def find_definition_token_in_file(path, name)
        mtime = File.mtime(path).to_i rescue 0
        cache_key = "#{path}:#{mtime}"
        tokens = @definition_file_token_cache[cache_key] ||= begin
          MilkTea::Lexer.lex(File.read(path), path: path_to_uri(path))
        end

        tokens.each_cons(2) do |kw_tok, id_tok|
          next unless MilkTea::LSP::Workspace::DEFINITION_KEYWORDS.include?(kw_tok.type)
          next unless id_tok.type == :identifier && id_tok.lexeme == name

          return id_tok
        end

        nil
      rescue StandardError
        nil
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

      # ── Formatting helpers ───────────────────────────────────────────────────

      def format_params(params)
        params.map { |p| "#{p.name}: #{p.type}" }.join(', ')
      end

      def resolve_dot_receiver_value_type(analysis, receiver_name, line, char)
        frame = enclosing_completion_frame(analysis, line)
        if frame
          snapshot = latest_completion_snapshot(frame, line, char)
          if snapshot && (binding = snapshot.bindings[receiver_name])
            return binding.type
          end
        end

        analysis.values[receiver_name]&.type
      end

      def resolve_local_hover_type(analysis, name, line, char)
        frame = enclosing_completion_frame(analysis, line)
        return nil unless frame

        snapshot = latest_completion_snapshot(frame, line, char)
        binding = snapshot&.bindings&.dig(name)
        return binding.type if binding

        future_snapshot = same_line_future_completion_snapshot(frame, line, char)
        future_snapshot&.bindings&.dig(name)&.type
      end

      def enclosing_completion_frame(analysis, line)
        frames = Array(analysis.local_completion_frames)
        containing = frames.select { |frame| frame.start_line && frame.end_line && frame.start_line <= line && line <= frame.end_line }
        containing.min_by { |frame| frame.end_line - frame.start_line }
      end

      def latest_completion_snapshot(frame, line, char)
        snapshots = Array(frame.snapshots)
        snapshots.reverse_each do |snapshot|
          next if snapshot.line > line
          next if snapshot.line == line && snapshot.column > char

          return snapshot
        end
        nil
      end

      def same_line_future_completion_snapshot(frame, line, char)
        snapshots = Array(frame.snapshots)
        snapshots.each do |snapshot|
          next unless snapshot.line == line
          next if snapshot.column <= char

          return snapshot
        end
        nil
      end

      def completion_items_for_value_receiver(analysis, receiver_type, prefix)
        items = []

        field_receiver_type = project_field_receiver_type_for_completion(receiver_type)
        if field_receiver_type.respond_to?(:fields)
          field_receiver_type.fields.each do |fname, ftype|
            next unless prefix.empty? || fname.start_with?(prefix)

            items << {
              label:      fname,
              kind:       10, # Property
              detail:     "#{fname}: #{ftype}",
              insertText: fname,
              sortText:   "0_#{fname}"
            }
          end
        end

        method_receiver_type = project_method_receiver_type_for_completion(receiver_type)
        methods = methods_for_receiver_type(analysis, method_receiver_type)
        methods.each do |mname, binding|
          next unless prefix.empty? || mname.start_with?(prefix)

          params_str = format_params(binding.type.params)
          items << {
            label:      mname,
            kind:       2,  # Method
            detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
            insertText: mname,
            sortText:   "1_#{mname}"
          }
        end

        items
      end

      def methods_for_receiver_type(analysis, receiver_type)
        methods = {}
        methods.merge!(analysis.methods.fetch(receiver_type, {})) if receiver_type
        analysis.imports.each_value do |module_binding|
          methods.merge!(module_binding.methods.fetch(receiver_type, {})) if module_binding.methods.key?(receiver_type)
        end
        methods
      end

      def project_field_receiver_type_for_completion(type)
        return type.arguments.first if ref_type_name?(type)
        return type.arguments.first if pointer_type_name?(type)

        type
      end

      def project_method_receiver_type_for_completion(type)
        return type.arguments.first if ref_type_name?(type)
        return type.arguments.first if pointer_type_name?(type)

        type
      end

      def ref_type_name?(type)
        type.is_a?(Types::GenericInstance) && type.name == 'ref' && type.arguments.length == 1
      end

      def pointer_type_name?(type)
        type.is_a?(Types::GenericInstance) && %w[ptr const_ptr].include?(type.name) && type.arguments.length == 1
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

      def symbol_kind(kind)
        case kind
        when 'function'   then 6
        when 'struct'     then 5
        when 'union'      then 5
        when 'enum'       then 10
        when 'type_alias' then 5
        when 'constant'   then 14
        when 'variable'   then 13
        else 1
        end
      end

      # Return the identifier prefix the user has typed before the cursor, for completion filtering.
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
        {
          start: { line: token.line - 1, character: token.column - 1 },
          end:   { line: token.line - 1, character: token.column - 1 + token.lexeme.length }
        }
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
    end
  end
end
