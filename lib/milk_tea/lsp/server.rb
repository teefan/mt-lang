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
    #   1. Hover         — real type signature from semantic facts
    #   2. Goto Def      — token-based definition site navigation
    #   3. Incremental   — textDocumentSync: 2 with range-based edits
    #   4. Multi-file    — workspace indexing via workspace/symbol
    #   5. Completion    — function/type/value completions from facts
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
      BUILTIN_FUNCTION_NAMES = %w[ref_of const_ptr_of ptr_of read fatal reinterpret array span zero default].to_set.freeze
      BUILTIN_ASSOCIATED_HOOK_NAMES = %w[hash equal order].to_set.freeze
      OPERATOR_TOKEN_TYPES = %i[
        amp colon comma caret dot lparen rparen pipe lbracket rbracket question
        equal plus minus star slash percent less greater tilde
        arrow shift_left shift_right plus_equal minus_equal star_equal slash_equal percent_equal
        amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
        equal_equal bang_equal less_equal greater_equal ellipsis
      ].to_set.freeze
      DIAGNOSTICS_WORKER_COUNT = Integer(ENV.fetch('MILK_TEA_LSP_DIAGNOSTICS_WORKERS', '2')).clamp(1, 8)

      def self.semantic_tokens_for_path(path, module_roots: nil, package_graph: nil)
        expanded_path = File.expand_path(path)
        roots = module_roots || MilkTea::ModuleRoots.roots_for_path(expanded_path)
        source = File.read(expanded_path)
        tokens = MilkTea::Lexer.lex(source, path: expanded_path)
        facts = MilkTea::ModuleLoader.new(
          module_roots: roots,
          package_graph: package_graph || load_package_graph(expanded_path),
        ).check_file(expanded_path)

        helper = allocate
        entries = helper.send(:build_semantic_token_entries, tokens, facts)
        data = helper.send(:encode_semantic_tokens, entries)

        {
          path: expanded_path,
          moduleName: facts.module_name,
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

      def self.load_package_graph(path, locked: false)
        PackageGraph.load(path, locked:)
      rescue PackageManifestError
        nil
      end
      private_class_method :load_package_graph

      def initialize(protocol: Protocol)
        @protocol = protocol
        @workspace = Workspace.new
        @format_mode = :tidy
        @dependency_resolution_mode = :auto
        @platform_override = nil
        @handlers = {}
        @diagnostic_report_cache = {}
        @semantic_tokens_cache = {}
        @fixall_cache = {}
        @definition_file_token_cache = {}
        @definition_file_ast_cache = {}
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
          message = @protocol.read_message
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
        @handlers['milkTea/documentContext'] = method(:handle_document_context)
        @handlers['textDocument/didOpen']   = method(:handle_did_open)
        @handlers['textDocument/didChange'] = method(:handle_did_change)
        @handlers['textDocument/didClose']  = method(:handle_did_close)
        @handlers['textDocument/didSave']   = method(:handle_did_save)

        # IDE features
        @handlers['textDocument/hover']             = method(:handle_hover)
        @handlers['textDocument/definition']        = method(:handle_definition)
        @handlers['textDocument/declaration']       = method(:handle_declaration)
        @handlers['textDocument/typeDefinition']    = method(:handle_type_definition)
        @handlers['textDocument/implementation']    = method(:handle_implementation)
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
        @protocol.write_error(id, -32_603, 'Internal server error') if id
      end

      def handle_request(method_name, params, id)
        handler = @handlers[method_name]
        if handler.nil?
          @protocol.write_error(id, -32_601, 'Method not found')
          return
        end

        begin
          @current_request_id = id
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          result = handler.call(params)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          if perf_logging? && (perf_verbose? || elapsed_ms > PERF_LOG_THRESHOLD_MS)
            detail = perf_log_context(method_name, params, verbose: perf_verbose?)
            warn "[LSP perf] req #{method_name} #{elapsed_ms}ms id=#{id}#{detail}"
          end
          @protocol.write_response(id, result)
        rescue StandardError => e
          warn "Error in handler for #{method_name}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          @protocol.write_error(id, -32_603, "Internal error: #{e.message}")
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
            detail = perf_log_context(method_name, params, verbose: perf_verbose?)
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
        @workspace.workspace_root_path = uri_to_path(@root_uri)
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
            implementationProvider: true,
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
        total_start = monotonic_time
        uri     = params['textDocument']['uri']
        content = params['textDocument']['text']
        source = @workspace.document_source(uri) || 'unknown'
        open_start = monotonic_time
        open_stats = @workspace.open_document(uri, content)
        open_ms = elapsed_ms(open_start)
        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
        diagnostics_start = monotonic_time
        schedule_diagnostics(uri, mode: :fast) unless @workspace.background_document?(uri)

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        facts_detail = if open_stats[:eager_facts]
                            "on(#{open_stats[:facts_mode] || :unknown})"
                          else
                            "off(#{open_stats[:skip_reason] || :unknown})"
                          end
        log_perf_breakdown(
          'textDocument/didOpen',
          elapsed,
          "uri=#{short_uri} source=#{source} bytes=#{open_stats[:bytes]} lines=#{open_stats[:lines]} imports=#{open_stats[:import_count]} shared_modules=#{open_stats[:shared_module_cache_size]} eager_facts=#{facts_detail} stages_ms=open:#{open_ms},facts:#{open_stats[:facts_ms] || 0.0},diagnostics_enqueue:#{elapsed_ms(diagnostics_start)}"
        )
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

        invalidate_document_caches(uri)
        refresh_open_document_dependency_state(uri)
        schedule_diagnostics(uri, mode: :fast) unless @workspace.background_document?(uri)
        nil
      end

      def handle_document_context(params)
        uri = params.dig('textDocument', 'uri') || params['uri']
        source = params['source']
        return nil unless uri && source

        previous_source = @workspace.set_document_source(uri, source)
        if previous_source == 'background-document' && source != 'background-document' && !@workspace.get_content(uri).empty?
          @semantic_tokens_cache.delete(uri)
          @fixall_cache.delete(uri)
          schedule_diagnostics(uri, force: true, mode: :fast)
        end

        nil
      end

      def handle_did_close(params)
        uri = params['textDocument']['uri']
        cancel_diagnostics(uri)
        @workspace.close_document(uri)
        invalidate_document_caches(uri)
        refresh_open_document_dependency_state(uri)
        @protocol.write_notification('textDocument/publishDiagnostics', {
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
        invalidate_document_caches(uri)
        refresh_open_document_dependency_state(uri)
        schedule_diagnostics(uri, force: true, mode: :full) unless @workspace.background_document?(uri)
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

        facts_start = monotonic_time
        facts = @workspace.get_facts(uri, allow_last_good_fallback: false)
        facts_ms = elapsed_ms(facts_start)

        build_start = monotonic_time
        semantic_entries = build_semantic_token_entries(tokens, facts)
        build_ms = elapsed_ms(build_start)

        encode_start = monotonic_time
        data = encode_semantic_tokens(semantic_entries)
        encode_ms = elapsed_ms(encode_start)

        @semantic_tokens_cache[uri] = { content_hash: cache_key, data: data }

        elapsed = elapsed_ms(total_start)
        short_uri = shorten_uri(uri) || uri
        log_perf_breakdown('textDocument/semanticTokens/full', elapsed,
                           "uri=#{short_uri} bytes=#{content.bytesize} lines=#{content.count("\n") + 1} cache=miss tokens=#{tokens.length} entries=#{semantic_entries.length} data_len=#{data.length} facts=on stages_ms=tokens:#{tokens_ms},facts:#{facts_ms},build:#{build_ms},encode:#{encode_ms}")

        { data: data }
      rescue StandardError => e
        warn "Error in semanticTokens/full handler: #{e.message}"
        { data: [] }
      end

      # ── Enhancement 1: Hover — real type signatures ──────────────────────────

      def handle_hover(params)
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri       = params['textDocument']['uri']
        lsp_line  = params['position']['line']
        lsp_char  = params['position']['character']
        token_kind = 'none'
        result_state = 'miss'

        context = measure_perf_stage(stages, 'context') { token_context_at(uri, lsp_line, lsp_char) }
        token = context&.fetch(:token, nil)
        token_kind = token&.type || :none
        unless token&.type == :identifier
          result_state = 'not-identifier'
          return nil
        end

        info = resolve_hover_info(uri, lsp_line, lsp_char, token: token, tokens: context[:tokens], token_index: context[:token_index], stages: stages)
        return nil unless info

        result = measure_perf_stage(stages, 'render') do
          {
            contents: {
              kind: 'markdown',
              value: render_hover_markdown(info)
            },
            range: token_to_range(token)
          }
        end
        result_state = 'hit'
        result
      rescue StandardError => e
        result_state = 'error'
        warn "Error in hover handler: #{e.message}"
        nil
      ensure
        log_request_stage_breakdown('textDocument/hover', total_start, uri: uri, stages: stages, summary: "token=#{token_kind} result=#{result_state}")
      end

      # Enhancement 2: Goto Definition ──────────────────────────────────────────

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

      # ── References ──────────────────────────────────────────────────────────

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
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        result_state = 'miss'

        ctx = measure_perf_stage(stages, 'call_context') { @workspace.find_call_context(uri, lsp_line, lsp_char) }
        return nil unless ctx

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        return nil unless facts

        binding = measure_perf_stage(stages, 'binding') { facts.functions[ctx[:name]] }
        return nil unless binding

        result = measure_perf_stage(stages, 'build') do
          params_list = binding.type.params
          params_str  = format_params(params_list)
          label       = "#{ctx[:name]}(#{params_str}) -> #{binding.type.return_type}"
          parameters  = params_list.map { |p| { label: "#{p.name}: #{p.type}" } }

          {
            signatures:      [{ label: label, parameters: parameters }],
            activeSignature: 0,
            activeParameter: ctx[:active_parameter]
          }
        end
        result_state = 'hit'
        result
      rescue StandardError => e
        result_state = 'error'
        warn "Error in signatureHelp handler: #{e.message}"
        nil
      ensure
        log_request_stage_breakdown('textDocument/signatureHelp', total_start, uri: uri, stages: stages, summary: "result=#{result_state}")
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
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri     = params['textDocument']['uri']
        symbols = measure_perf_stage(stages, 'symbols') { @workspace.get_symbols(uri) }
        result = measure_perf_stage(stages, 'format') { symbols.map { |sym| format_symbol(sym, uri) } }
        result
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      ensure
        symbol_count = defined?(result) && result ? result.length : 0
        log_request_stage_breakdown('textDocument/documentSymbol', total_start, uri: uri, stages: stages, summary: "symbols=#{symbol_count}")
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

        dependency_resolution_mode = dependency_resolution_mode_from_settings(settings)
        apply_dependency_resolution_mode(dependency_resolution_mode) if dependency_resolution_mode

        platform_provided, platform_override = platform_override_from_settings(settings)
        apply_platform_override(platform_override) if platform_provided

        strict_root_provided, strict_root_enabled = strict_current_root_diagnostics_from_settings(settings)
        apply_strict_current_root_diagnostics(strict_root_enabled) if strict_root_provided
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

      def dependency_resolution_mode_from_settings(settings)
        return nil unless settings.is_a?(Hash)

        mode =
          settings.dig('milkTea', 'lsp', 'dependencyResolution') ||
          settings.dig('milk_tea', 'lsp', 'dependencyResolution') ||
          settings.dig('lsp', 'dependencyResolution')
        return nil unless mode

        normalized = DependencyResolution.normalize_mode(mode)
        return normalized if DependencyResolution::MODES.include?(normalized)

        nil
      end

      def platform_override_from_settings(settings)
        return [false, nil] unless settings.is_a?(Hash)

        value =
          settings.dig('milkTea', 'lsp', 'platform') ||
          settings.dig('milk_tea', 'lsp', 'platform') ||
          settings.dig('lsp', 'platform')
        return [false, nil] if value.nil?

        normalized = value.to_s.strip.downcase
        return [true, nil] if normalized.empty? || normalized == 'auto'

        [true, ModuleLoader.normalize_platform_name(normalized)]
      rescue ArgumentError
        [false, nil]
      end

      def strict_current_root_diagnostics_from_settings(settings)
        return [false, nil] unless settings.is_a?(Hash)

        value =
          settings.dig('milkTea', 'lsp', 'strictCurrentRootDiagnostics') ||
          settings.dig('milk_tea', 'lsp', 'strictCurrentRootDiagnostics') ||
          settings.dig('lsp', 'strictCurrentRootDiagnostics')
        return [false, nil] if value.nil?

        normalized = case value
                     when true, false
                       value
                     else
                       case value.to_s.strip.downcase
                       when 'true', '1', 'yes', 'on'
                         true
                       when 'false', '0', 'no', 'off', ''
                         false
                       else
                         return [false, nil]
                       end
                     end

        [true, normalized]
      end

      def apply_dependency_resolution_mode(mode)
        normalized = DependencyResolution.normalize_mode(mode)
        return if @dependency_resolution_mode == normalized

        @dependency_resolution_mode = normalized
        @workspace.dependency_resolution_mode = normalized
        @diagnostic_report_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, mode: :full) unless @workspace.background_document?(uri)
        end
      end

      def apply_platform_override(platform)
        normalized = platform.nil? ? nil : ModuleLoader.normalize_platform_name(platform)
        return if @platform_override == normalized

        @platform_override = normalized
        @workspace.platform_override = normalized
        @diagnostic_report_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, mode: :full) unless @workspace.background_document?(uri)
        end
      end

      def apply_strict_current_root_diagnostics(enabled)
        normalized = !!enabled
        return if @workspace.strict_current_root_diagnostics_enabled == normalized

        @workspace.strict_current_root_diagnostics_enabled = normalized
        @diagnostic_report_cache.clear
        open_uris = @workspace.open_document_uris
        invalidate_document_caches_for(open_uris)
        open_uris.each do |uri|
          schedule_diagnostics(uri, force: true, mode: :full) unless @workspace.background_document?(uri)
        end
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
        reserved_primitive_name_fixes = nil

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
          when 'reserved-primitive-name'
            reserved_primitive_name_fixes ||= Linter.collect_reserved_primitive_name_fixes(content, path: uri)
            fix = reserved_primitive_name_fixes.find do |candidate|
              declaration_site = candidate.sites.first
              declaration_site.line == diag_line && declaration_site.column == (diag_start_char + 1)
            end
            next unless fix

            edits = fix.sites.uniq { |site| [site.line, site.column] }.sort_by { |site| [site.line, site.column] }.map do |site|
              {
                range: {
                  start: { line: site.line - 1, character: site.column - 1 },
                  end:   { line: site.line - 1, character: site.column - 1 + site.length }
                },
                newText: fix.replacement_name
              }
            end

            actions << {
              title: "Rename '#{fix.original_name}' to '#{fix.replacement_name}'",
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => edits
                }
              }
            }

          when 'prefer-let'
            # Replace `var` with `let` on the declaration line
            source_line = lines[diag_line - 1].to_s
            next unless source_line.match?(/\bvar\b/)

            new_line = source_line.sub(/\bvar\b/, 'let')
            actions << {
              title: Linter.quick_fix_title('prefer-let'),
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
              title: Linter.quick_fix_title('redundant-else'),
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

          when 'redundant-unsafe'
            next if source_line.empty?
            if source_line.match?(/\A\s*unsafe:\s*\z/)
              lines = content.lines
              unsafe_idx = diag_line - 1
              first_body_idx = unsafe_idx + 1
              next if first_body_idx >= lines.length

              unsafe_indent = lines[unsafe_idx].match(/\A(\s*)/)[1]
              body_indent = unsafe_indent + '    '

              body_end_idx = first_body_idx - 1
              (first_body_idx...lines.length).each do |i|
                line = lines[i]
                if line.chomp.empty? || line.start_with?(body_indent)
                  body_end_idx = i
                else
                  break
                end
              end
              next if body_end_idx < first_body_idx

              new_body = lines[first_body_idx..body_end_idx].map { |line| line.sub(/\A    /, '') }.join
              actions << {
                title: Linter.quick_fix_title('redundant-unsafe'),
                kind: 'quickFix',
                diagnostics: [diag],
                edit: {
                  changes: {
                    uri => [{
                      range: {
                        start: { line: unsafe_idx,       character: 0 },
                        end:   { line: body_end_idx + 1, character: 0 }
                      },
                      newText: new_body
                    }]
                  }
                }
              }
            else
              new_line = Linter.remove_inline_unsafe_prefix(source_line, column: diag_start_char + 1)
              next if new_line == source_line

              actions << {
                title: Linter.quick_fix_title('redundant-unsafe'),
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

          when 'redundant-return'
            next unless source_line.match?(/\A\s*return\s*\z/)

            actions << {
              title: Linter.quick_fix_title('redundant-return'),
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

          when 'redundant-read-cast'
            next if source_line.empty?

            cast_text = source_line[diag_start_char...diag_end_char].to_s
            next if cast_text.empty?

            replacement = cast_text[/\A\s*(?:ptr|const_ptr|ref)\[[^\)]*\]<-\s*([A-Za-z_][A-Za-z0-9_]*)\s*\z/, 1]
            next unless replacement

            actions << {
              title: Linter.quick_fix_title('redundant-read-cast'),
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

          when 'redundant-cast'
            next if source_line.empty?

            cast_text = source_line[diag_start_char...diag_end_char].to_s
            next if cast_text.empty?

            replacement = Linter.extract_prefix_cast_source_text(cast_text)
            next unless replacement

            actions << {
              title: Linter.quick_fix_title('redundant-cast'),
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

          when 'redundant-read-release-temp'
            fix = Linter.build_read_release_temp_fix(content.lines, diag_line - 1)
            next unless fix

            actions << {
              title: Linter.quick_fix_title('redundant-read-release-temp'),
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: fix[:start_line_idx], character: 0 },
                      end:   { line: fix[:end_line_idx] + 1, character: 0 }
                    },
                    newText: fix[:new_text]
                  }]
                }
              }
            }

          when 'prefer-let-else'
            fix = Linter.build_prefer_let_else_fix(content.lines, diag_line - 1)
            next unless fix

            actions << {
              title: Linter.quick_fix_title('prefer-let-else'),
              kind: 'quickFix',
              diagnostics: [diag],
              edit: {
                changes: {
                  uri => [{
                    range: {
                      start: { line: fix[:start_line_idx], character: 0 },
                      end:   { line: fix[:end_line_idx] + 1, character: 0 }
                    },
                    newText: fix[:new_text]
                  }]
                }
              }
            }

          when 'directional-ffi-arg'
            next if source_line.empty?

            argument_text = source_line[diag_start_char...diag_end_char].to_s
            next if argument_text.empty?

            replacement = Linter.rewrite_directional_ffi_argument(argument_text)
            next if replacement == argument_text

            actions << {
              title: Linter.quick_fix_title('directional-ffi-arg'),
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
              title: Linter::FIX_ALL_TITLE,
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

      def handle_document_diagnostic(params)
        uri = params.dig('textDocument', 'uri')
        return { kind: 'full', items: [] } unless uri

        content = @workspace.get_content(uri)
        diagnostics = @workspace.collect_diagnostics(uri, mode: :full)
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

        facts = @workspace.get_facts(uri)
        tokens = @workspace.get_tokens(uri)
        return [] unless facts && tokens

        hints = []
        i = 0
        while i < tokens.length - 1
          callee = tokens[i]
          next_tok = tokens[i + 1]

          # Skip function definitions — `function foo(` has the same identifier+lparen
          # shape as a call site but must not get parameter-name inlay hints.
          prev_tok = i > 0 ? tokens[i - 1] : nil

          # Also support module-qualified call sites (`mod.fn(...)`).
          # Ignore identifiers immediately after `.` to avoid treating member names
          # as unqualified local calls.
          if callee.type == :identifier && prev_tok&.type != :function && prev_tok&.type != :dot
            binding = nil
            lparen_index = nil

            if next_tok&.type == :lparen
              binding = facts.functions[callee.lexeme]
              lparen_index = i + 1
            elsif next_tok&.type == :dot
              member = tokens[i + 2]
              member_lparen = tokens[i + 3]
              if member&.type == :identifier && member_lparen&.type == :lparen
                module_binding = facts.imports[callee.lexeme]
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
                next if self_describing_argument_expression?(tokens, arg_tok)
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
        stages = new_perf_stages
        total_start = stages ? monotonic_time : nil
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']
        branch = 'none'
        item_count = 0

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        unless facts
          branch = 'no-facts'
          return { isIncomplete: false, items: [] }
        end

        prefix = measure_perf_stage(stages, 'prefix') { current_word_prefix(uri, lsp_line, lsp_char) }

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
                result << {
                  label:      fname,
                  kind:       3,  # Function
                  detail:     "function #{fname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: fname,
                  sortText:   "0_#{fname}"
                }
              end
              module_binding.values.each do |vname, binding|
                next unless prefix.empty? || vname.start_with?(prefix)
                result << {
                  label:      vname,
                  kind:       6,  # Variable
                  detail:     "#{vname}: #{binding.type}",
                  insertText: vname,
                  sortText:   "1_#{vname}"
                }
              end
              module_binding.types.each do |tname, _type|
                next unless prefix.empty? || tname.start_with?(prefix)
                result << {
                  label:      tname,
                  kind:       7,  # Class
                  detail:     "type #{tname}",
                  insertText: tname,
                  sortText:   "2_#{tname}"
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
                    kind:       20, # EnumMember
                    detail:     "#{receiver_label}.#{mname}",
                    insertText: mname,
                    sortText:   "0_#{mname}"
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
                    kind:       20, # EnumMember
                    detail:     "#{receiver_label}.#{aname}",
                    insertText: aname,
                    sortText:   "0_#{aname}"
                  }
                end
              end
              item_count = items.length
              return { isIncomplete: false, items: items }
            end

            items = measure_perf_stage(stages, 'build') { completion_items_for_type_receiver(facts, type, prefix) }
            unless items.empty?
              branch = 'type-receiver'
              item_count = items.length
              return { isIncomplete: false, items: items }
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
                result << {
                  label:      mname,
                  kind:       2,  # Method
                  detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
                  insertText: mname,
                  sortText:   "0_#{mname}"
                }
              end
            end
            result
          end
          item_count = method_items.length
          return { isIncomplete: false, items: method_items }
        end

        branch = 'global'
        items = measure_perf_stage(stages, 'build') do
          result = []

          # Functions
          facts.functions.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            params_str = format_params(binding.type.params)
            result << {
              label:        name,
              kind:         3,  # Function
              detail:       "function #{name}(#{params_str}) -> #{binding.type.return_type}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "0_#{name}"
            }
          end

          # Types
          builtin_names = Sema::BUILTIN_TYPE_NAMES
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
              insertTextFormat: 1,
              sortText:     "1_#{name}"
            }
          end

          # Imported modules
          facts.imports.each do |name, module_binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         9,  # Module
              detail:       "module #{module_binding.name}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "2_#{name}"
            }
          end

          # Values
          facts.values.each do |name, binding|
            next unless prefix.empty? || name.start_with?(prefix)

            result << {
              label:        name,
              kind:         6,  # Variable
              detail:       "#{name}: #{binding.type}",
              insertText:   name,
              insertTextFormat: 1,
              sortText:     "3_#{name}"
            }
          end

          result
        end

        item_count = items.length
        { isIncomplete: false, items: items }
      rescue StandardError => e
        branch = 'error'
        warn "Error in completion handler: #{e.message}"
        { isIncomplete: false, items: [] }
      ensure
        log_request_stage_breakdown('textDocument/completion', total_start, uri: uri, stages: stages, summary: "branch=#{branch} items=#{item_count}")
      end

      def completion_items_for_type_receiver(facts, receiver_type, prefix)
        methods_for_receiver_type(facts, receiver_type).filter_map do |mname, binding|
          next unless binding.ast.is_a?(AST::MethodDef) && binding.ast.kind == :static
          next unless prefix.empty? || mname.start_with?(prefix)

          params_str = format_params(binding.type.params)
          {
            label:      mname,
            kind:       2,  # Method
            detail:     "#{mname}(#{params_str}) -> #{binding.type.return_type}",
            insertText: mname,
            sortText:   "0_#{mname}"
          }
        end
      end

      def resolve_type_receiver_info(facts, receiver_name, receiver_path)
        if facts.types.key?(receiver_name)
          type = facts.types.fetch(receiver_name)
          module_name = type.respond_to?(:module_name) ? type.module_name : facts.module_name
          return { label: receiver_name, type:, module_name: }
        end

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
        binding = methods_for_receiver_type(facts, receiver_type)[method_name]
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
        refs = @workspace.find_all_references(target[:binding].name)
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
        affected_uris = Set.new
        changes.each do |change|
          uri = change['uri']
          type = change['type']
          next unless uri

          affected_uris.merge(@workspace.apply_watched_file_change(uri, type))
        end

        invalidate_document_caches_for(affected_uris)
        affected_uris.each do |affected_uri|
          schedule_diagnostics(affected_uri, force: true, mode: :fast) unless @workspace.background_document?(affected_uri)
        end
        nil
      end

      def invalidate_document_caches(uri)
        @semantic_tokens_cache.delete(uri)
        @fixall_cache.delete(uri)
      end

      def invalidate_document_caches_for(uris)
        uris.each { |uri| invalidate_document_caches(uri) }
      end

      def refresh_open_document_dependency_state(changed_uri)
        affected_uris = @workspace.refresh_open_document_dependency_caches(changed_uri)
        invalidate_document_caches_for(affected_uris)
        affected_uris.each do |affected_uri|
          schedule_diagnostics(affected_uri, force: true, mode: :fast) unless @workspace.background_document?(affected_uri)
        end
        affected_uris
      end

      # ── Diagnostics ──────────────────────────────────────────────────────────

      def schedule_diagnostics(uri, force: false, mode: :fast)
        content = @workspace.get_content(uri)
        content_digest = Digest::SHA256.hexdigest(content)
        normalized_mode = mode.to_s == 'full' ? :full : :fast
        enqueue = false

        @diagnostics_mutex.synchronize do
          if !force && @diagnostics_last_scheduled_hash[uri] == content_digest
            @diagnostics_perf[:skipped_unchanged] += 1 if perf_logging?
            return
          end

          @diagnostics_generation[uri] += 1
          @diagnostics_last_scheduled_hash[uri] = content_digest
          @diagnostics_perf[:scheduled] += 1 if perf_logging?
          @diagnostics_pending[uri] = {
            generation: @diagnostics_generation[uri],
            content: content,
            mode: normalized_mode,
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

          diagnostics = collect_diagnostics_for_content(uri, snapshot[:content], mode: snapshot[:mode])
          publish = false
          @diagnostics_mutex.synchronize do
            publish = snapshot[:generation] == @diagnostics_generation[uri]
          end

          if publish
            @diagnostics_perf[:published] += 1 if perf_logging?
            @protocol.write_notification('textDocument/publishDiagnostics', {
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

      def collect_diagnostics_for_content(uri, _content, mode: :fast)
        @workspace.collect_diagnostics(uri, mode: mode)
      rescue StandardError => e
        warn "LSP diagnostics error #{uri}: #{e.message}"
        []
      end

      # ── Enhancement 1 helpers: hover type resolution ─────────────────────────

      def resolve_hover_info(uri, lsp_line, lsp_char, token: nil, tokens: nil, token_index: nil, stages: nil)
        if token.nil?
          context = measure_perf_stage(stages, 'context') { token_context_at(uri, lsp_line, lsp_char) }
          return nil unless context

          token = context[:token]
          tokens = context[:tokens]
          token_index = context[:token_index]
        end

        return nil unless token&.type == :identifier

        tokens ||= @workspace.get_tokens(uri) || []
        token_index = tokens.index(token) if token_index.nil?
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

        facts = measure_perf_stage(stages, 'facts') { @workspace.get_facts(uri) }
        return nil unless facts

        if token_index && field_declaration_token?(tokens, token_index)
          return resolve_field_declaration_hover_info(uri, facts, tokens, token_index)
        end

        if token_index && named_argument_label_token?(tokens, token_index)
          return resolve_named_argument_label_hover_info(uri, facts, tokens, token_index)
        end

        if token_index && (member_hover = resolve_member_access_hover_info(uri, facts, tokens, token_index))
          return member_hover
        end

        if token_index && (enum_member_hover = resolve_enum_member_hover_info(uri, facts, tokens, token_index))
          return enum_member_hover
        end

        name = token.lexeme
        signature = nil
        docs = nil
        source_location = nil

        if (binding = method_binding_at_token(facts, token))
          signature = method_signature(binding)
          source_location = module_member_binding_location(uri, facts.module_name, name, binding)
        elsif (binding = facts.functions[name])
          params_str = format_params(binding.type.params)
          signature = "function #{name}(#{params_str}) -> #{binding.type.return_type}"
        elsif (binding = facts.interfaces[name])
          signature = interface_signature(binding)
          source_location = module_member_definition_location(uri, binding.module_name, name)
        elsif facts.types.key?(name)
          type = facts.types[name]
          signature = type_hover_signature(name, type)
        elsif (binding = facts.values[name])
          signature = value_hover_signature(binding)
        elsif (import_binding = facts.imports[name])
          signature = "module #{import_binding.name}"
          source_location = module_definition_location(uri, import_binding.name)
        else
          dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          dot_receiver_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
          if dot_receiver && (module_binding = facts.imports[dot_receiver])
            if (fn = module_binding.functions[name])
              params_str = format_params(fn.type.params)
              signature = "function #{name}(#{params_str}) -> #{fn.type.return_type}"
              source_location = module_member_binding_location(uri, module_binding.name, name, fn)
            elsif (val = module_binding.values[name])
              signature = value_hover_signature(val)
            elsif module_binding.types.key?(name)
              signature = "type #{name}"
            elsif (binding = module_binding.interfaces[name])
              signature = interface_signature(binding)
              source_location = module_member_definition_location(uri, module_binding.name, name)
            end

            if signature
              source_location ||= module_member_definition_location(uri, module_binding.name, name)
              source_location ||= module_definition_location(uri, module_binding.name)
            end
          end

          unless signature
            if (type_method = resolve_static_type_receiver_method(facts, dot_receiver, dot_receiver_path, name))
              signature = method_signature(type_method[:binding])
              source_location = module_member_binding_location(uri, type_method[:module_name], name, type_method[:binding])
              source_location ||= module_member_definition_location(uri, type_method[:module_name], name)
              source_location ||= module_definition_location(uri, type_method[:module_name])
            end
          end

          unless signature
            if token_index && (builtin_info = builtin_hover_info(name, tokens, token_index))
              signature = builtin_info[:signature]
              docs = builtin_info[:docs]
            end
          end

          unless signature
            if token_index && match_arm_binding_token?(tokens, token_index)
              if (local_binding = resolve_as_binding_declaration_hover_binding(facts, name, lsp_line + 1, lsp_char + 1))
                signature = value_hover_signature(local_binding)
              end
            end
          end

          unless signature
            if (local_binding = resolve_local_hover_binding(facts, name, lsp_line + 1, lsp_char + 1))
              signature = value_hover_signature(local_binding)
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
                             measure_perf_stage(stages, 'definition_entry') { hover_definition_entry_from_location(source_location) }
                           else
                             measure_perf_stage(stages, 'global_definition') do
                               @workspace.find_definition_token_global(
                                 name,
                                 preferred_uri: uri,
                                 before_line: lsp_line + 1,
                                 before_char: lsp_char + 1,
                               )
                             end
                           end

        source_uri = hover_source_uri_for_definition(definition_entry) || hover_source_uri_from_location(source_location)
        source_line = hover_source_line_for_definition(definition_entry) || hover_source_line_from_location(source_location)

        {
          signature: signature,
          docs: docs || hover_doc_comment_for_definition(definition_entry),
          source: hover_source_label_for_definition(definition_entry) || hover_source_label_from_location(source_location),
          source_uri: source_uri,
          source_line: source_line,
        }
      end

      def token_context_at(uri, lsp_line, lsp_char)
        tokens = @workspace.get_tokens(uri) || []
        interpolation_context = fstring_interpolation_token_context(tokens, lsp_line, lsp_char)
        return interpolation_context if interpolation_context

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token

        {
          token: token,
          tokens: tokens,
          token_index: tokens.index(token),
        }
      end

      def fstring_interpolation_token_context(tokens, lsp_line, lsp_char)
        target_line = lsp_line + 1
        target_char = lsp_char + 1

        fstring_token = tokens.find do |token|
          next false unless token.type == :fstring

          token_contains_position?(token, target_line, target_char)
        end
        return nil unless fstring_token

        Array(fstring_token.literal).each do |part|
          next unless part[:kind] == :expr
          next unless part[:line] == target_line

          expression_tokens = interpolation_expression_tokens(part)
          token = expression_tokens.find { |candidate| token_contains_position?(candidate, target_line, target_char) }
          next unless token

          return {
            token: token,
            tokens: expression_tokens,
            token_index: expression_tokens.index(token),
          }
        end

        nil
      end

      def interpolation_expression_tokens(part)
        source = part[:source]
        return [] if source.nil? || source.strip.empty?

        MilkTea::Lexer.new(source).lex
          .reject { |token| [:newline, :indent, :dedent, :eof].include?(token.type) }
          .map do |token|
            adjusted_line = part[:line] + token.line - 1
            adjusted_column = token.line == 1 ? (part[:column] + token.column - 1) : token.column

            token.with(
              line: adjusted_line,
              column: adjusted_column,
              start_offset: nil,
              end_offset: nil,
              leading_trivia: [].freeze,
              trailing_trivia: [].freeze,
            )
          end
      rescue MilkTea::LexError
        []
      end

      def token_contains_position?(token, target_line, target_char)
        segments = token.lexeme.split("\n", -1)
        end_line = token.line + segments.length - 1
        return false if target_line < token.line || target_line > end_line

        if segments.length == 1
          return token.column <= target_char && target_char < (token.column + segments.first.length)
        end

        if target_line == token.line
          return token.column <= target_char && target_char <= (token.column + segments.first.length - 1)
        end

        target_char <= segments.fetch(target_line - token.line).length
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

            if token_index && (member_access = module_member_access_info(tokens, token_index))
              module_name = facts.imports[member_access[:receiver]]&.name || imported_module_name_from_ast(uri, member_access[:receiver])
              if module_name
                location = module_member_definition_location(uri, module_name, token.lexeme)
                location ||= module_definition_location(uri, module_name)
              end
            elsif token_index && (field_location = resolve_field_member_definition_location(uri, facts, tokens, token_index))
              location = field_location
            elsif token_index && (enum_member_location = resolve_enum_member_definition_location(uri, facts, tokens, token_index))
              location = enum_member_location
            else
              dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
              dot_receiver_path = @workspace.find_dot_receiver_path(uri, lsp_line, lsp_char)
              imported_module_name = dot_receiver ? (facts.imports[dot_receiver]&.name || imported_module_name_from_ast(uri, dot_receiver)) : nil
              if imported_module_name
                location = module_member_definition_location(uri, imported_module_name, token.lexeme) || module_definition_location(uri, imported_module_name)
              elsif (type_method = resolve_static_type_receiver_method(facts, dot_receiver, dot_receiver_path, token.lexeme))
                location = module_member_binding_location(uri, type_method[:module_name], token.lexeme, type_method[:binding]) ||
                  module_member_definition_location(uri, type_method[:module_name], token.lexeme) ||
                  module_definition_location(uri, type_method[:module_name])
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

      def build_semantic_token_entries(tokens, facts = nil)
        # Precompute line → non-trivia tokens index so non_trivia_tokens_on_line
        # is O(1) per call instead of O(n), turning the overall build from O(n²) to O(n).
        trivia_types = Set[:newline, :indent, :dedent, :eof]
        @tokens_by_line_cache = Hash.new { |h, k| h[k] = [] }
        tokens.each { |t| @tokens_by_line_cache[t.line] << t unless trivia_types.include?(t.type) }

        entries = []

        tokens.each_with_index do |tok, index|
          next if [:newline, :indent, :dedent, :eof].include?(tok.type)

          if tok.type == :fstring
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
      end

      # Decomposes an fstring token into non-overlapping semantic token entries.
      # Text segments are emitted as :string and interpolation expression segments
      # are emitted semantically. Delimiter punctuation is left to TextMate.
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
        return false unless [:string, :cstring].include?(token.type)

        tag = token.lexeme[/\A(?:c)?<<-([A-Za-z_][A-Za-z0-9_]*)[ \t]*\n/, 1]
        return false if tag.nil?

        %w[GLSL VERT FRAG COMP JSON JSONC SQL].include?(tag)
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

        if prev_tok&.type == :const
          return [:variable, ['declaration', 'readonly']]
        end

        if prev_tok && [:let, :var].include?(prev_tok.type)
          return [:variable, ['declaration']]
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

        return [:property, []] if named_argument_label_token?(tokens, index)

        if facts && prev_tok&.type != :dot && (generic_binding = generic_function_lexical_binding_semantic(facts, tok))
          return generic_binding
        end

        if next_tok&.type == :dot && facts
          if (binding = local_semantic_value_binding(facts, tok, allow_same_line_future: parameter_declaration))
            return semantic_value_binding_entry(binding, declaration: binding.kind == :param && parameter_declaration)
          end

          return [:type, []] if facts.types.key?(name)
          return [:type, []] if facts.interfaces.key?(name)
          return [:namespace, []] if facts.imports.key?(name)

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
          return [:type, []] if facts.types.key?(name)
          return [:type, []] if facts.interfaces.key?(name)

          if DEFAULT_LIBRARY_TYPE_NAMES.include?(name)
            return [:type, ['defaultLibrary']]
          end
        end

        if facts

          if (binding = local_semantic_value_binding(facts, tok, allow_same_line_future: parameter_declaration))
            return semantic_value_binding_entry(binding, declaration: binding.kind == :param && parameter_declaration)
          end

          return [:type, []] if facts.types.key?(name)
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
        return false unless type_parameter_names_in_scope(facts, tok.line).include?(tok.lexeme)
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
      # type name receiver, e.g. `Option.none`, `Result[int, str].success`.
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
        MilkTea::MtimeTool.mtime(path: path).cache_key
      rescue MilkTea::MtimeToolError, SystemCallError
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

      def interface_signature(binding)
        method_lines = binding.methods.values.map do |method|
          "    #{interface_method_signature(method)}"
        end

        (["interface #{binding.name}"] + method_lines).join("\n")
      end

      def interface_method_signature(binding)
        keyword = binding.kind == :mutable ? 'mutable function' : 'function'
        keyword = "async #{keyword}" if binding.async
        "#{keyword} #{binding.name}(#{format_params(binding.params)}) -> #{binding.return_type}"
      end

      def resolve_dot_receiver_value_type(facts, receiver_name, line, char)
        local_type = resolve_local_hover_type(facts, receiver_name, line, char)
        return local_type if local_type

        facts.values[receiver_name]&.type
      end

      def resolve_member_access_hover_info(current_uri, facts, tokens, token_index)
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
            source_location = field_definition_location(current_uri, field_receiver_type, segment[:name])

            if segment[:token_index] == token_index
              return {
                signature: field_hover_signature(segment[:name], field_type),
                docs: nil,
                source: hover_source_label_from_location(source_location),
                source_uri: hover_source_uri_from_location(source_location),
                source_line: hover_source_line_from_location(source_location),
              }
            end

            current_type = field_type
            next
          end

          next unless segment[:token_index] == token_index

          method_receiver_type = project_method_receiver_type_for_completion(current_type)
          method_info = member_method_info_for_receiver_type(facts, method_receiver_type, segment[:name])
          return nil unless method_info

          source_location = module_member_binding_location(current_uri, method_info[:module_name], segment[:name], method_info[:binding])
          source_location ||= module_member_definition_location(current_uri, method_info[:module_name], segment[:name])

          return {
            signature: method_signature(method_info[:binding]),
            docs: nil,
            source: hover_source_label_from_location(source_location),
            source_uri: hover_source_uri_from_location(source_location),
            source_line: hover_source_line_from_location(source_location),
          }
        end

        nil
      end

      def member_method_info_for_receiver_type(facts, receiver_type, method_name)
        return nil unless receiver_type

        dispatch_receiver_type = method_dispatch_receiver_type_for_completion(receiver_type)

        if (binding = facts.methods.fetch(receiver_type, {})[method_name])
          return {
            binding: binding,
            module_name: facts.module_name,
          }
        end

        if dispatch_receiver_type != receiver_type && (binding = facts.methods.fetch(dispatch_receiver_type, {})[method_name])
          return {
            binding: binding,
            module_name: facts.module_name,
          }
        end

        facts.imports.each_value do |module_binding|
          binding = module_binding.methods.fetch(receiver_type, {})[method_name]
          if binding.nil? && dispatch_receiver_type != receiver_type
            binding = module_binding.methods.fetch(dispatch_receiver_type, {})[method_name]
          end
          next unless binding

          return {
            binding: binding,
            module_name: module_binding.name,
          }
        end

        nil
      end

      def resolve_enum_member_hover_info(current_uri, facts, tokens, token_index)
        member_info = resolve_enum_member_access_info(current_uri, facts, tokens, token_index)
        return nil unless member_info

        signature = "#{member_info[:member_name]}: #{member_info[:receiver_label]}"
        signature += " = #{member_info[:value_text]}" if member_info[:value_text]

        {
          signature: signature,
          docs: nil,
          source: hover_source_label_from_location(member_info[:location]),
          source_uri: hover_source_uri_from_location(member_info[:location]),
          source_line: hover_source_line_from_location(member_info[:location]),
        }
      end

      def resolve_enum_member_definition_location(current_uri, facts, tokens, token_index)
        resolve_enum_member_access_info(current_uri, facts, tokens, token_index)&.fetch(:location, nil)
      end

      def resolve_enum_member_access_info(current_uri, facts, tokens, token_index)
        return nil unless type_name_member_access?(tokens, token_index, facts)

        token = tokens[token_index]
        token_end_char = token.column - 1 + token.lexeme.length
        receiver_name = @workspace.find_dot_receiver(current_uri, token.line - 1, token_end_char)
        receiver_path = @workspace.find_dot_receiver_path(current_uri, token.line - 1, token_end_char)
        receiver_info = resolve_type_receiver_info(facts, receiver_name, receiver_path)
        return nil unless receiver_info

        receiver_type = receiver_info[:type]
        return nil unless receiver_type.is_a?(Types::EnumBase)
        return nil unless receiver_type.member(token.lexeme)

        owner_module_name = receiver_type.respond_to?(:module_name) ? receiver_type.module_name : receiver_info[:module_name]

        {
          receiver_label: receiver_info[:label],
          member_name: token.lexeme,
          value_text: enum_member_value_text(current_uri, owner_module_name, receiver_type.name, token.lexeme),
          location: enum_member_definition_location(current_uri, owner_module_name, receiver_type.name, token.lexeme),
        }
      end

      def resolve_field_declaration_hover_info(current_uri, facts, tokens, token_index)
        receiver_info = field_declaration_receiver_info(facts, tokens, token_index)
        return nil unless receiver_info

        field_name = tokens[token_index].lexeme
        receiver_type = project_field_receiver_type_for_completion(receiver_info[:type])
        return nil unless receiver_type.respond_to?(:field)

        field_type = receiver_type.field(field_name)
        return nil unless field_type

        source_location = field_definition_location(current_uri, receiver_type, field_name)

        {
          signature: field_hover_signature(field_name, field_type),
          docs: nil,
          source: hover_source_label_from_location(source_location),
          source_uri: hover_source_uri_from_location(source_location),
          source_line: hover_source_line_from_location(source_location),
        }
      end

      def resolve_named_argument_label_hover_info(current_uri, facts, tokens, token_index)
        receiver_info = named_argument_label_receiver_info(facts, tokens, token_index)
        return nil unless receiver_info

        field_name = tokens[token_index].lexeme
        receiver_type = project_field_receiver_type_for_completion(receiver_info[:type])
        return nil unless receiver_type.respond_to?(:field)

        field_type = receiver_type.field(field_name)
        return nil unless field_type

        source_location = field_definition_location(current_uri, receiver_type, field_name)

        {
          signature: field_hover_signature(field_name, field_type),
          docs: nil,
          source: hover_source_label_from_location(source_location),
          source_uri: hover_source_uri_from_location(source_location),
          source_line: hover_source_line_from_location(source_location),
        }
      end

      def field_declaration_receiver_info(facts, tokens, token_index)
        token = tokens[token_index]
        return nil unless token

        i = token_index - 1
        while i >= 0
          current = tokens[i]
          i -= 1

          next if [:newline, :indent, :dedent, :eof].include?(current.type)
          next if current.line == token.line
          next if current.column >= token.column

          header_line_tokens = non_trivia_tokens_on_line(tokens, current.line)
          header = header_line_tokens.first
          return nil unless [:struct, :union].include?(header&.type)

          type_token = header_line_tokens[1]
          return nil unless type_token&.type == :identifier

          return resolve_type_receiver_info(facts, type_token.lexeme, type_token.lexeme)
        end

        nil
      end

      def named_argument_label_receiver_info(facts, tokens, token_index)
        opener_index = parameter_list_opener_index(tokens, token_index)
        return nil unless opener_index

        head_index = previous_non_trivia_token_index(tokens, opener_index)
        return nil unless head_index

        if tokens[head_index].type == :rbracket
          lbracket_index = matching_opener_index(tokens, head_index)
          return nil unless lbracket_index

          head_index = previous_non_trivia_token_index(tokens, lbracket_index)
          return nil unless head_index
        end

        head = tokens[head_index]
        return nil unless head.type == :identifier

        receiver_name = head.lexeme
        receiver_path = receiver_name

        dot_index = previous_non_trivia_token_index(tokens, head_index)
        if dot_index && tokens[dot_index].type == :dot
          module_index = previous_non_trivia_token_index(tokens, dot_index)
          return nil unless module_index && tokens[module_index].type == :identifier

          receiver_path = "#{tokens[module_index].lexeme}.#{receiver_name}"
        end

        resolve_type_receiver_info(facts, receiver_name, receiver_path)
      end

      def member_access_chain_at(tokens, token_index)
        token = tokens[token_index]
        return nil unless token&.type == :identifier

        indices = [token_index]
        current_index = token_index

        loop do
          dot_index = previous_non_trivia_token_index(tokens, current_index)
          break unless dot_index && tokens[dot_index].type == :dot && tokens[dot_index].line == token.line

          receiver_index = previous_non_trivia_token_index(tokens, dot_index)
          break unless receiver_index && tokens[receiver_index].type == :identifier && tokens[receiver_index].line == token.line

          indices.unshift(receiver_index)
          current_index = receiver_index
        end

        current_index = token_index
        loop do
          dot_index = next_non_trivia_token_index(tokens, current_index + 1)
          break unless dot_index && tokens[dot_index].type == :dot && tokens[dot_index].line == token.line

          member_index = next_non_trivia_token_index(tokens, dot_index + 1)
          break unless member_index && tokens[member_index].type == :identifier && tokens[member_index].line == token.line

          indices << member_index
          current_index = member_index
        end

        return nil if indices.length < 2

        {
          line: token.line,
          char: token.column + token.lexeme.length,
          segments: indices.each_with_index.map do |index, position|
            {
              name: tokens[index].lexeme,
              token_index: index,
              position: position,
            }
          end,
        }
      end

      def method_binding_at_token(facts, token)
        facts.methods.each_value do |methods|
          methods.each_value do |binding|
            next unless binding.name == token.lexeme
            next unless binding.ast.is_a?(AST::MethodDef)
            next unless binding.ast.line == token.line
            next unless binding.ast.respond_to?(:column) && binding.ast.column == token.column

            return binding
          end
        end

        nil
      end

      def method_signature(binding)
        params_str = format_params(binding.type.params)
        keyword = case binding.ast.kind
                  when :mutable
                    "mutable function"
                  when :static
                    "static function"
                  else
                    "function"
                  end

        "#{keyword} #{binding.name}(#{params_str}) -> #{binding.type.return_type}"
      end

      def type_hover_signature(name, type)
        rendered_type = type.to_s
        return "type #{name}" if rendered_type == name

        "type #{name} = #{rendered_type}"
      end

      def field_hover_signature(name, type)
        "field #{name}: #{type}"
      end

      BUILTIN_CALL_HOVER_INFO = {
        'fatal' => {
          signature: 'builtin fatal(message) -> never',
          docs: '`fatal(message)` aborts execution with the provided message.'
        },
        'ref_of' => {
          signature: 'builtin ref_of(value) -> ref[T]',
          docs: '`ref_of(x)` borrows a mutable safe lvalue as `ref[T]`.'
        },
        'const_ptr_of' => {
          signature: 'builtin const_ptr_of(value) -> const_ptr[T]',
          docs: '`const_ptr_of(x)` takes the address of a safe lvalue as `const_ptr[T]`.'
        },
        'ptr_of' => {
          signature: 'builtin ptr_of(value) -> ptr[T]',
          docs: '`ptr_of(x)` takes the address of a mutable safe lvalue as `ptr[T]`.'
        },
        'read' => {
          signature: 'builtin read(value) -> T',
          docs: '`read(value)` projects a `ref[T]` or pointer-like value to its referent.'
        },
      }.freeze

      def builtin_hover_info(name, tokens, token_index)
        specialization_info = builtin_value_specialization_info(name, tokens, token_index)
        return specialization_info if specialization_info

        associated_hook_info = builtin_associated_hook_hover_info(name, tokens, token_index)
        return associated_hook_info if associated_hook_info

        type_constructor_info = builtin_type_constructor_hover_info(name, tokens, token_index)
        return type_constructor_info if type_constructor_info

        builtin_call_hover_info(name, tokens, token_index)
      end

      def builtin_value_specialization_info(name, tokens, token_index)
        return nil unless %w[zero default reinterpret].include?(name)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        target_type = render_builtin_specialization(tokens[(lbracket_index + 1)...rbracket_index])
        return nil if target_type.empty?

        docs = case name
               when 'zero'
                 '`zero[T]` returns the raw zero-initialized value for `T`.'
               when 'default'
                 '`default[T]` requires an accessible zero-argument associated function `T.default()` that returns `T`.'
               when 'reinterpret'
                 '`reinterpret[T](value)` bit-casts a value to `T`; it requires `unsafe` and compatible concrete sized types.'
               end

        {
          signature: if name == 'reinterpret'
                       "builtin #{specialization}(value) -> #{target_type}"
                     else
                       "builtin #{specialization} -> #{target_type}"
                     end,
          docs: docs,
        }
      end

      def builtin_type_constructor_hover_info(name, tokens, token_index)
        return nil unless %w[array span Option Result].include?(name)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)

        if after_bracket_index && tokens[after_bracket_index].type == :lparen
          docs = if name == 'array'
                   '`array[T, N](...)` constructs a fixed-length array value of type `array[T, N]`.'
                 else
                   '`span[T](data = ..., len = ...)` constructs a span view over contiguous `T` storage.'
                 end

          return {
            signature: if name == 'array'
                         "builtin #{specialization}(...) -> #{specialization}"
                       else
                         "builtin #{specialization}(data = ..., len = ...) -> #{specialization}"
                       end,
            docs: docs,
          }
        end

        docs = case name
               when 'array'
                 '`array[T, N]` is the built-in fixed-length array type.'
               when 'span'
                 '`span[T]` is the built-in non-owning contiguous view type.'
               when 'Option'
                 '`Option[T]` is the built-in optional value type with `some(value = ...)` and `none` arms.'
               else
                 '`Result[T, E]` is the built-in success/failure type with `success(value = ...)` and `failure(error = ...)` arms.'
               end

        {
          signature: "builtin type #{specialization}",
          docs: docs,
        }
      end

      def builtin_associated_hook_hover_info(name, tokens, token_index)
        return nil unless BUILTIN_ASSOCIATED_HOOK_NAMES.include?(name)

        lbracket_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless lbracket_index && tokens[lbracket_index].type == :lbracket

        rbracket_index = matching_closer_index(tokens, lbracket_index, :lbracket, :rbracket)
        return nil unless rbracket_index

        after_bracket_index = next_non_trivia_token_index(tokens, rbracket_index + 1)
        return nil unless after_bracket_index && tokens[after_bracket_index].type == :lparen

        specialization = render_builtin_specialization(tokens[token_index..rbracket_index])
        docs = case name
               when 'hash'
                 '`hash[T](value)` lowers to `T.hash(value: const_ptr[T]) -> uint` after borrowing safe lvalues or forwarding existing refs and pointers.'
               when 'equal'
                 '`equal[T](left, right)` lowers to `T.equal(left: const_ptr[T], right: const_ptr[T]) -> bool` after borrowing safe lvalues or forwarding existing refs and pointers.'
               when 'order'
                 '`order[T](left, right)` lowers to `T.order(left: const_ptr[T], right: const_ptr[T]) -> int` after borrowing safe lvalues or forwarding existing refs and pointers.'
               end

        signature = case name
                    when 'hash'
                      "builtin #{specialization}(value) -> uint"
                    when 'equal'
                      "builtin #{specialization}(left, right) -> bool"
                    when 'order'
                      "builtin #{specialization}(left, right) -> int"
                    end

        {
          signature: signature,
          docs: docs,
        }
      end

      def builtin_call_hover_info(name, tokens, token_index)
        info = BUILTIN_CALL_HOVER_INFO[name]
        return nil unless info

        next_index = next_non_trivia_token_index(tokens, token_index + 1)
        return nil unless next_index && tokens[next_index].type == :lparen

        info
      end

      def render_builtin_specialization(tokens)
        Array(tokens).map(&:lexeme).join.gsub(',', ', ')
      end

      def value_hover_signature(binding)
        case binding.kind
        when :const
          "const #{binding.name}: #{binding.type} (immutable)"
        when :var
          "var #{binding.name}: #{binding.type} (mutable)"
        when :let
          "let #{binding.name}: #{binding.type} (immutable)"
        when :param
          "parameter #{binding.name}: #{binding.type} (immutable)"
        when :local
          suffix = binding.mutable ? 'mutable' : 'immutable'
          "local #{binding.name}: #{binding.type} (#{suffix})"
        else
          "#{binding.name}: #{binding.type}"
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

      def resolve_local_hover_binding(facts, name, line, char)
        declared_binding = declared_generic_local_hover_binding(facts, name, line)
        return declared_binding if declared_binding

        frame = enclosing_completion_frame(facts, line)
        return nil unless frame

        snapshot = latest_completion_snapshot(frame, line, char)
        binding = snapshot&.bindings&.dig(name)
        return binding if binding

        future_snapshot = same_line_future_completion_snapshot(frame, line, char)
        future_snapshot&.bindings&.dig(name)
      end

      def resolve_as_binding_declaration_hover_binding(facts, name, line, char)
        frame = enclosing_completion_frame(facts, line)
        return nil unless frame

        Array(frame.snapshots).each do |snapshot|
          next if snapshot.line < line
          next if snapshot.line == line && snapshot.column <= char

          binding = snapshot.bindings[name]
          return binding if binding
        end

        nil
      end

      def resolve_local_hover_type(facts, name, line, char)
        resolve_local_hover_binding(facts, name, line, char)&.type
      end

      def declared_generic_local_hover_binding(facts, name, line)
        binding = generic_function_binding_for_line(facts, line)
        return nil unless binding

        binding.body_params.find { |param| param.name == name }
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

      def enclosing_completion_frame(facts, line)
        frames = Array(facts.local_completion_frames)
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

      def completion_items_for_value_receiver(facts, receiver_type, prefix)
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
        methods = methods_for_receiver_type(facts, method_receiver_type)
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

          return Types::Nullable.new(dispatch_base_type)
        end

        return receiver_type unless receiver_type.is_a?(Types::GenericInstance)

        dispatch_receiver_type = Types::GenericInstance.new(
          receiver_type.name,
          receiver_type.arguments.each_with_index.map do |argument, index|
            argument.is_a?(Types::LiteralTypeArg) ? argument : Types::TypeVar.new("__receiver_arg#{index}")
          end,
        )

        dispatch_receiver_type == receiver_type ? receiver_type : dispatch_receiver_type
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
        when 'interface'  then 11
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
        end_line, end_character = token_end_position(token)

        {
          start: { line: token.line - 1, character: token.column - 1 },
          end:   { line: end_line, character: end_character }
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
    end
  end
end
