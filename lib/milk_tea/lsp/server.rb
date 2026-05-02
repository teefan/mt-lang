# frozen_string_literal: true

require 'cgi/escape'
require 'pathname'
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
    #   5. Code Lens     — function signature annotations above def sites
    #   6. Completion    — function/type/value completions from analysis
    class Server
      def initialize
        @workspace = Workspace.new
        @handlers = {}
        @diagnostic_report_cache = {}
        register_handlers
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
        @handlers['textDocument/documentHighlight'] = method(:handle_document_highlight)
        @handlers['textDocument/documentSymbol']    = method(:handle_document_symbols)
        @handlers['textDocument/formatting']        = method(:handle_formatting)
        @handlers['textDocument/rangeFormatting']   = method(:handle_range_formatting)
        @handlers['textDocument/completion']        = method(:handle_completion)
        @handlers['textDocument/codeLens']          = method(:handle_code_lens)
        @handlers['textDocument/codeAction']        = method(:handle_code_action)
        @handlers['textDocument/inlayHint']         = method(:handle_inlay_hint)
        @handlers['textDocument/diagnostic']        = method(:handle_document_diagnostic)
        @handlers['textDocument/signatureHelp']     = method(:handle_signature_help)
        @handlers['textDocument/prepareRename']     = method(:handle_prepare_rename)
        @handlers['textDocument/rename']            = method(:handle_rename)

        # Workspace
        @handlers['workspace/symbol'] = method(:handle_workspace_symbol)
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
      PERF_LOG_THRESHOLD_MS = 20

      def perf_logging?
        @perf_logging ||= !ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s.empty?
      end

      def perf_verbose?
        @perf_verbose ||= ENV.fetch('MILK_TEA_LSP_PERF', nil).to_s == 'verbose'
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
        file_path = uri_to_path(uri)
        return true if library_uri?(uri)
        return true if file_path&.include?('/std/')

        # Heuristic thresholds to avoid expensive full-file formatter/linter runs.
        return true if content.bytesize > 200_000
        return true if content.count("\n") > 1200

        false
      rescue StandardError
        false
      end

      # ── Lifecycle handlers ───────────────────────────────────────────────────

      def handle_initialize(params)
        @root_uri = params['rootUri']
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
            diagnosticProvider: {
              interFileDependencies: false,
              workspaceDiagnostics: false
            },
            completionProvider: {
              triggerCharacters: ['.', '(', ' '],
              resolveProvider: false
            },
            renameProvider: { prepareProvider: true },
            codeLensProvider: {
              resolveProvider: false
            },
            workspaceSymbolProvider: true
          }
        }
      end

      def handle_initialized(_params)
        # Enhancement 4: index all .mt files in the workspace root
        @workspace.index_workspace(@root_uri) if @root_uri
        nil
      end

      def handle_shutdown(_params)
        nil
      end

      def handle_exit(_params)
        exit(0)
      end

      # ── Text document sync ───────────────────────────────────────────────────

      def handle_did_open(params)
        uri     = params['textDocument']['uri']
        content = params['textDocument']['text']
        @workspace.open_document(uri, content)
        publish_diagnostics(uri)
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

        publish_diagnostics(uri)
        nil
      end

      def handle_did_close(params)
        uri = params['textDocument']['uri']
        @workspace.close_document(uri)
        nil
      end

      def handle_did_save(params)
        uri = params.dig('textDocument', 'uri')
        return nil unless uri

        text = params['text']
        @workspace.update_document(uri, text) if text
        publish_diagnostics(uri)
        nil
      end

      # ── Enhancement 1: Hover — real type signatures ──────────────────────────

      def handle_hover(params)
        uri       = params['textDocument']['uri']
        lsp_line  = params['position']['line']
        lsp_char  = params['position']['character']

        info = resolve_hover_info(uri, lsp_line, lsp_char)
        return nil unless info

        { contents: { kind: 'markdown', value: "```milk-tea\n#{info}\n```" } }
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

        formatted = Formatter.format_source(content, mode: :safe)
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
        formatted_segment = Formatter.format_source(segment, mode: :safe)

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

      def handle_code_action(params)
        uri    = params.dig('textDocument', 'uri')
        return [] unless uri

        content = @workspace.get_content(uri)
        return [] unless content

        actions = []

        # ── Per-diagnostic quickfix actions ──────────────────────────────────
        requested_diagnostics = params.dig('context', 'diagnostics') || []
        requested_diagnostics.each do |diag|
          code = diag['code']
          diag_line = diag.dig('range', 'start', 'line').to_i + 1  # 1-based

          case code
          when 'prefer-let'
            # Replace `var` with `let` on the declaration line
            lines = content.lines
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
            # diag_line is the first body statement (1-based).
            lines = content.lines
            first_body_idx = diag_line - 1
            next if first_body_idx < 1

            else_idx = (0...first_body_idx).to_a.reverse.find do |i|
              lines[i]&.match?(/\A\s*else:\s*\z/)
            end
            next unless else_idx

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
          end
        end

        # ── source.fixAll: apply all auto-fixes at once ────────────────────
        # Skip for files outside the workspace root (library/std files) since
        # formatting and linting a large stdlib file costs seconds per call.
        unless library_uri?(uri)
          begin
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
        end

        actions
      rescue StandardError => e
        warn "Error in codeAction handler: #{e.message}"
        []
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

        analysis = @workspace.get_analysis(uri)
        tokens = @workspace.get_tokens(uri)
        return [] unless analysis && tokens

        hints = []
        i = 0
        while i < tokens.length - 1
          callee = tokens[i]
          lparen = tokens[i + 1]

          if callee.type == :identifier && lparen.type == :lparen
            binding = analysis.functions[callee.lexeme]
            if binding
              arg_starts, closing_index = collect_call_argument_starts(tokens, i + 1)
              params_list = binding.type.params

              arg_starts.each_with_index do |arg_tok, index|
                break if index >= params_list.length
                next unless position_in_range?(arg_tok.line - 1, arg_tok.column - 1, start_line, start_char, end_line, end_char)

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

        # When user is typing after '.', return method completions only.
        dot_recv = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
        if dot_recv
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

      # ── Enhancement 5: Code Lens ─────────────────────────────────────────────

      def handle_code_lens(params)
        uri      = params['textDocument']['uri']
        content  = @workspace.get_content(uri)
        return [] if skip_expensive_source_fix_all?(uri, content)

        analysis = @workspace.get_analysis(uri)
        return [] unless analysis

        lenses = []

        analysis.functions.each do |name, binding|
          def_tok = @workspace.find_definition_token(uri, name)
          next unless def_tok

          params_str = format_params(binding.type.params)
          signature  = "#{name}(#{params_str}) -> #{binding.type.return_type}"

          lenses << {
            range: {
              start: { line: def_tok.line - 1, character: 0 },
              end:   { line: def_tok.line - 1, character: def_tok.column - 1 + name.length }
            },
            command: {
              title:   signature,
              command: 'milk-tea.showSignature',
              arguments: [signature]
            }
          }
        end

        lenses
      rescue StandardError => e
        warn "Error in codeLens handler: #{e.message}"
        []
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

      def publish_diagnostics(uri)
        diagnostics = @workspace.collect_diagnostics(uri)

        Protocol.write_notification('textDocument/publishDiagnostics', {
          uri:         uri,
          diagnostics: diagnostics
        })
      end

      # ── Enhancement 1 helpers: hover type resolution ─────────────────────────

      def resolve_hover_info(uri, lsp_line, lsp_char)
        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        analysis = @workspace.get_analysis(uri)
        return nil unless analysis

        name = token.lexeme

        if (binding = analysis.functions[name])
          params_str = format_params(binding.type.params)
          "def #{name}(#{params_str}) -> #{binding.type.return_type}"
        elsif analysis.types.key?(name)
          type = analysis.types[name]
          "type #{name} = #{type}"
        elsif (binding = analysis.values[name])
          "#{name}: #{binding.type}"
        elsif (import_binding = analysis.imports[name])
          "module #{import_binding.name}"
        else
          dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          if dot_receiver && (module_binding = analysis.imports[dot_receiver])
            if (fn = module_binding.functions[name])
              params_str = format_params(fn.type.params)
              return "def #{name}(#{params_str}) -> #{fn.type.return_type}"
            elsif (val = module_binding.values[name])
              return "#{name}: #{val.type}"
            elsif module_binding.types.key?(name)
              return "type #{name}"
            end
          end

          # Fallback: check if it is a method defined on any type
          analysis.methods.each do |_recv_type, methods|
            if (mb = methods[name])
              params_str = format_params(mb.type.params)
              return "def #{name}(#{params_str}) -> #{mb.type.return_type}"
            end
          end
          nil
        end
      end

      def resolve_definition_location(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        analysis = @workspace.get_analysis(uri)
        if analysis
          dot_receiver = @workspace.find_dot_receiver(uri, lsp_line, lsp_char)
          if dot_receiver && analysis.imports.key?(dot_receiver)
            module_name = analysis.imports.fetch(dot_receiver).name
            return module_definition_location(uri, module_name)
          elsif analysis.imports.key?(token.lexeme)
            module_name = analysis.imports.fetch(token.lexeme).name
            return module_definition_location(uri, module_name)
          end
        end

        found = @workspace.find_definition_token_global(token.lexeme, preferred_uri: uri)
        return nil unless found

        {
          uri: found[:uri],
          range: token_to_range(found[:token])
        }
      end

      def module_definition_location(current_uri, module_name)
        current_path = uri_to_path(current_uri)
        return nil unless current_path

        module_roots = MilkTea::ModuleRoots.roots_for_path(current_path)
        relative_path = File.join(*module_name.split('.')) + '.mt'
        path = module_roots.lazy.map { |root| File.join(root, relative_path) }.find { |candidate| File.file?(candidate) }
        return nil unless path

        {
          uri: path_to_uri(File.expand_path(path)),
          range: {
            start: { line: 0, character: 0 },
            end: { line: 0, character: 0 }
          }
        }
      end

      # ── Formatting helpers ───────────────────────────────────────────────────

      def format_params(params)
        params.map { |p| "#{p.name}: #{p.type}" }.join(', ')
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

      def uri_to_path(uri)
        parsed = URI.parse(uri)
        return nil unless parsed.scheme == 'file'

        CGI.unescape(parsed.path)
      rescue URI::InvalidURIError
        nil
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
