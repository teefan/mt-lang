# frozen_string_literal: true

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
        register_handlers
      end

      def run
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
        @handlers['textDocument/references']        = method(:handle_references)
        @handlers['textDocument/documentHighlight'] = method(:handle_document_highlight)
        @handlers['textDocument/documentSymbol']    = method(:handle_document_symbols)
        @handlers['textDocument/formatting']        = method(:handle_formatting)
        @handlers['textDocument/completion']        = method(:handle_completion)
        @handlers['textDocument/codeLens']          = method(:handle_code_lens)
        @handlers['textDocument/signatureHelp']     = method(:handle_signature_help)
        @handlers['textDocument/prepareRename']     = method(:handle_prepare_rename)
        @handlers['textDocument/rename']            = method(:handle_rename)

        # Workspace
        @handlers['workspace/symbol'] = method(:handle_workspace_symbol)
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
          result = handler.call(params)
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
          handler.call(params)
        rescue StandardError => e
          warn "Error in notification handler for #{method_name}: #{e.message}"
        end
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
            referencesProvider: true,
            documentHighlightProvider: true,
            documentSymbolProvider: true,
            documentFormattingProvider: true,
            signatureHelpProvider: {
              triggerCharacters: ['(', ','],
              retriggerCharacters: [',']
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
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        token = @workspace.find_token_at(uri, lsp_line, lsp_char)
        return nil unless token&.type == :identifier

        def_tok = @workspace.find_definition_token(uri, token.lexeme)
        return nil unless def_tok

        {
          uri: uri,
          range: token_to_range(def_tok)
        }
      rescue StandardError => e
        warn "Error in definition handler: #{e.message}"
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

        unless params.dig('context', 'includeDeclaration') == false
          return refs
        end

        def_tok = @workspace.find_definition_token(uri, token.lexeme)
        return refs unless def_tok

        def_line = def_tok.line - 1
        def_char = def_tok.column - 1
        refs.reject { |r| r[:uri] == uri && r[:range][:start][:line] == def_line && r[:range][:start][:character] == def_char }
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

      # ── Enhancement 6: Completion ────────────────────────────────────────────

      def handle_completion(params)
        uri      = params['textDocument']['uri']
        lsp_line = params['position']['line']
        lsp_char = params['position']['character']

        analysis = @workspace.get_analysis(uri)
        return { isIncomplete: false, items: [] } unless analysis

        prefix = current_word_prefix(uri, lsp_line, lsp_char)

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
              command: 'milk-tea.showSignature'
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

      # ── Diagnostics ──────────────────────────────────────────────────────────

      def publish_diagnostics(uri)
        content     = @workspace.get_content(uri)
        diagnostics = Diagnostics.collect(uri, content)

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
        end
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
    end
  end
end
