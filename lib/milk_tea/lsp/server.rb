# frozen_string_literal: true


require 'cgi/escape'
require 'digest'
require 'pathname'
require 'set'
require 'thread'
require 'uri'


require_relative "server/call_hierarchy"
require_relative "server/code_actions"
require_relative "server/code_lens"
require_relative "server/completion"
require_relative "server/configuration"
require_relative "server/definition"
require_relative "server/diagnostics_scheduling"
require_relative "server/folding_range"
require_relative "server/formatting"
require_relative "server/hover"
require_relative "server/inlay_hints"
require_relative "server/lifecycle"
require_relative "server/on_type_formatting"
require_relative "server/progress"
require_relative "server/references"
require_relative "server/rename"
require_relative "server/selection_range"
require_relative "server/semantic_tokens"
require_relative "server/signature_help"
require_relative "server/text_documents"
require_relative "server/type_hierarchy"
require_relative "server/utilities"

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
      BUILTIN_FUNCTION_NAMES = %w[
        ref_of const_ptr_of ptr_of read fatal reinterpret array span zero default
        field_of callable_of has_attribute attribute_of attribute_arg
      ].to_set.freeze
      BUILTIN_ASSOCIATED_HOOK_NAMES = %w[hash equal order].to_set.freeze
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
        'field_of' => {
          signature: 'builtin field_of(Type, field_name) -> field_handle',
          docs: '`field_of(Type, field_name)` returns a compile-time handle for the named field on a struct type.'
        },
        'callable_of' => {
          signature: 'builtin callable_of(name) -> callable_handle',
          docs: '`callable_of(name)` returns a compile-time handle for a callable declaration name.'
        },
        'has_attribute' => {
          signature: 'builtin has_attribute(target, attribute_name) -> bool',
          docs: '`has_attribute(target, attribute_name)` checks at compile time whether the resolved attribute is applied to the target.'
        },
        'attribute_of' => {
          signature: 'builtin attribute_of(target, attribute_name) -> attribute_handle',
          docs: '`attribute_of(target, attribute_name)` returns the applied attribute handle for the resolved target-and-attribute pair; use `has_attribute(...)` when absence is expected.'
        },
      }.freeze
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
        @workspace_diagnostic_cache = {}
        @semantic_tokens_cache = {}
        @semantic_tokens_delta_cache = {}
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
        @cancelled_requests_mutex = Mutex.new
        @cancelled_request_ids = Set.new
        register_handlers
        start_diagnostics_workers
      end

      def run
        if perf_logging?
          mode = perf_verbose? ? 'verbose' : 'threshold'
          warn "[LSP perf] enabled mode=#{mode} threshold_ms=#{Workspace::PERF_LOG_THRESHOLD_MS}"
        end

        loop do
          message = @protocol.read_message
          break if message.nil?
          next if message.equal?(Protocol::INVALID_MESSAGE)

          process_message(message)
        end
      rescue StandardError => e
        warn "Server error: #{e.message}"
        raise
      end


      private

      include ServerCallHierarchy
      include ServerCodeActions
      include ServerCodeLens
      include ServerCompletion
      include ServerConfiguration
      include ServerDefinition
      include ServerDiagnosticsScheduling
      include ServerFoldingRange
      include ServerFormatting
      include ServerHover
      include ServerInlayHints
      include ServerLifecycle
      include ServerOnTypeFormatting
      include ServerProgress
      include ServerReferences
      include ServerRename
      include ServerSelectionRange
      include ServerSemanticTokens
      include ServerSignatureHelp
      include ServerTextDocuments
      include ServerTypeHierarchy
      include ServerUtilities

      # ── Handler registration ─────────────────────────────────────────────────

      def register_handlers
        # Lifecycle
        @handlers['initialize']  = method(:handle_initialize)
        @handlers['initialized'] = method(:handle_initialized)
        @handlers['shutdown']    = method(:handle_shutdown)
        @handlers['exit']        = method(:handle_exit)
        @handlers['$/cancelRequest'] = method(:handle_cancel_request)

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
        @handlers['textDocument/onTypeFormatting']   = method(:handle_on_type_formatting)
        @handlers['textDocument/foldingRange']       = method(:handle_folding_range)
        @handlers['textDocument/completion']        = method(:handle_completion)
        @handlers['completionItem/resolve']         = method(:handle_completion_resolve)
        @handlers['textDocument/codeAction']        = method(:handle_code_action)
        @handlers['textDocument/codeLens']           = method(:handle_code_lens)
        @handlers['codeLens/resolve']                 = method(:handle_code_lens_resolve)
        @handlers['textDocument/prepareCallHierarchy'] = method(:handle_prepare_call_hierarchy)
        @handlers['callHierarchy/incomingCalls']     = method(:handle_incoming_calls)
        @handlers['callHierarchy/outgoingCalls']     = method(:handle_outgoing_calls)
        @handlers['textDocument/inlayHint']         = method(:handle_inlay_hint)
        @handlers['textDocument/semanticTokens/full'] = method(:handle_semantic_tokens_full)
        @handlers['textDocument/semanticTokens/full/delta'] = method(:handle_semantic_tokens_delta)
        @handlers['textDocument/semanticTokens/range'] = method(:handle_semantic_tokens_range)
        @handlers['textDocument/selectionRange']     = method(:handle_selection_range)
        @handlers['textDocument/diagnostic']         = method(:handle_document_diagnostic)
        @handlers['workspace/diagnostic']            = method(:handle_workspace_diagnostic)
        @handlers['textDocument/signatureHelp']     = method(:handle_signature_help)
        @handlers['textDocument/prepareTypeHierarchy'] = method(:handle_prepare_type_hierarchy)
        @handlers['typeHierarchy/supertypes']        = method(:handle_supertypes)
        @handlers['typeHierarchy/subtypes']          = method(:handle_subtypes)
        @handlers['textDocument/prepareRename']     = method(:handle_prepare_rename)
        @handlers['textDocument/rename']            = method(:handle_rename)

        # Workspace
        @handlers['workspace/symbol'] = method(:handle_workspace_symbol)
        @handlers['workspace/didChangeWorkspaceFolders'] = method(:handle_did_change_workspace_folders)
        @handlers['workspace/didChangeConfiguration'] = method(:handle_did_change_configuration)
        @handlers['workspace/didChangeWatchedFiles'] = method(:handle_did_change_watched_files)
      end

      # ── Message dispatch ─────────────────────────────────────────────────────

      def process_message(message)
        method_name = message['method']
        params = message['params'] || {}
        id     = message['id']

        if message.key?('id') && !message.key?('method')
          Protocol.handle_response(message)
        elsif message.key?('id')
          handle_request(method_name, params, id)
        else
          handle_notification(method_name, params)
        end
      rescue StandardError => e
        warn "Error processing message: #{e.message}"
        @protocol.write_error(id, -32_603, 'Internal server error') if id && message.key?('method')
      end

      def handle_request(method_name, params, id)
        if request_cancelled?(id)
          clear_cancelled_request(id)
          @protocol.write_error(id, -32_800, 'Request cancelled')
          return
        end

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
          if perf_logging? && (perf_verbose? || elapsed_ms > Workspace::PERF_LOG_THRESHOLD_MS)
            detail = perf_log_context(method_name, params, verbose: perf_verbose?)
            warn "[LSP perf] req #{method_name} #{elapsed_ms}ms id=#{id}#{detail}"
          end
          if request_cancelled?(id)
            clear_cancelled_request(id)
            @protocol.write_error(id, -32_800, 'Request cancelled')
          else
            @protocol.write_response(id, result)
          end
        rescue StandardError => e
          warn "Error in handler for #{method_name}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          @protocol.write_error(id, -32_603, "Internal error: #{e.message}")
        ensure
          clear_cancelled_request(id)
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
          if perf_logging? && (perf_verbose? || elapsed_ms > Workspace::PERF_LOG_THRESHOLD_MS)
            detail = perf_log_context(method_name, params, verbose: perf_verbose?)
            warn "[LSP perf] ntf #{method_name} #{elapsed_ms}ms#{detail}"
          end
        rescue StandardError => e
          warn "Error in notification handler for #{method_name}: #{e.message}"
        end
      end
    end
  end
end
