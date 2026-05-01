# frozen_string_literal: true

module MilkTea
  module LSP
    # Main LSP server - handles JSON-RPC message loop and dispatch
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

      def register_handlers
        # Lifecycle
        @handlers['initialize'] = method(:handle_initialize)
        @handlers['shutdown'] = method(:handle_shutdown)
        @handlers['exit'] = method(:handle_exit)

        # Text Document
        @handlers['textDocument/didOpen'] = method(:handle_did_open)
        @handlers['textDocument/didChange'] = method(:handle_did_change)
        @handlers['textDocument/didClose'] = method(:handle_did_close)
        @handlers['textDocument/hover'] = method(:handle_hover)
        @handlers['textDocument/definition'] = method(:handle_definition)
        @handlers['textDocument/documentSymbol'] = method(:handle_document_symbols)
        @handlers['textDocument/formatting'] = method(:handle_formatting)
      end

      def process_message(message)
        method = message['method']
        params = message['params'] || {}
        id = message['id']

        if message.key?('id')
          # Request - must send response
          handle_request(method, params, id)
        else
          # Notification - no response needed
          handle_notification(method, params)
        end
      rescue StandardError => e
        warn "Error processing message: #{e.message}"
        Protocol.write_error(id, -32603, 'Internal server error') if id
      end

      def handle_request(method, params, id)
        handler = @handlers[method]
        if handler.nil?
          Protocol.write_error(id, -32601, 'Method not found')
          return
        end

        begin
          result = handler.call(params)
          Protocol.write_response(id, result)
        rescue StandardError => e
          warn "Error in handler for #{method}: #{e.message}"
          Protocol.write_error(id, -32603, "Internal error: #{e.message}")
        end
      end

      def handle_notification(method, params)
        handler = @handlers[method]
        return unless handler

        begin
          handler.call(params)
        rescue StandardError => e
          warn "Error in notification handler for #{method}: #{e.message}"
        end
      end

      # Handlers

      def handle_initialize(_params)
        {
          capabilities: {
            textDocumentSync: 1,
            hoverProvider: true,
            definitionProvider: true,
            documentSymbolProvider: true,
            formattingProvider: true
          }
        }
      end

      def handle_shutdown(_params)
        nil
      end

      def handle_exit(_params)
        exit(0)
      end

      def handle_did_open(params)
        uri = params['textDocument']['uri']
        content = params['textDocument']['text']
        @workspace.open_document(uri, content)
        publish_diagnostics(uri)
        nil
      end

      def handle_did_change(params)
        uri = params['textDocument']['uri']
        changes = params['contentChanges'] || []

        # For full document sync, use the text from the last change
        content = changes.last&.dig('text') || ''
        @workspace.update_document(uri, content)
        publish_diagnostics(uri)
        nil
      end

      def handle_did_close(params)
        uri = params['textDocument']['uri']
        @workspace.close_document(uri)
        nil
      end

      def handle_hover(params)
        uri = params['textDocument']['uri']
        line = params['position']['line']
        character = params['position']['character']

        content = @workspace.get_content(uri)
        type_info = find_type_at(content, line, character)

        return nil if type_info.nil?

        {
          contents: format_hover(type_info)
        }
      rescue StandardError => e
        warn "Error in hover handler: #{e.message}"
        nil
      end

      def handle_definition(params)
        uri = params['textDocument']['uri']
        line = params['position']['line']
        character = params['position']['character']

        symbol = find_symbol_at(uri, line, character)
        return nil if symbol.nil?

        definition = find_definition(symbol)
        return nil if definition.nil?

        {
          uri: uri,
          range: {
            start: { line: definition[:line] - 1, character: 0 },
            end: { line: definition[:line], character: 0 }
          }
        }
      rescue StandardError => e
        warn "Error in definition handler: #{e.message}"
        nil
      end

      def handle_document_symbols(params)
        uri = params['textDocument']['uri']
        symbols = @workspace.get_symbols(uri)

        symbols.map { |sym| format_symbol(sym, uri) }
      rescue StandardError => e
        warn "Error in documentSymbol handler: #{e.message}"
        []
      end

      def handle_formatting(params)
        uri = params['textDocument']['uri']
        content = @workspace.get_content(uri)

        formatted = Formatter.format_source(content, mode: :safe)

        # Return single edit replacing entire document
        [
          {
            range: {
              start: { line: 0, character: 0 },
              end: { line: 999_999, character: 0 }
            },
            newText: formatted
          }
        ]
      rescue StandardError => e
        warn "Error in formatting handler: #{e.message}"
        []
      end

      # Helpers

      def publish_diagnostics(uri)
        content = @workspace.get_content(uri)
        diagnostics = Diagnostics.collect(uri, content)

        Protocol.write_notification('textDocument/publishDiagnostics', {
          uri: uri,
          diagnostics: diagnostics
        })
      end

      def find_type_at(content, line, character)
        # Simplified: just return "unknown" for now
        # Full implementation would parse and do type lookup
        'unknown'
      rescue StandardError
        'unknown'
      end

      def find_symbol_at(_uri, _line, _character)
        # Simplified: return nil for now
        # Full implementation would parse and find symbol at position
        nil
      end

      def find_definition(_symbol)
        # Simplified: return nil for now
        # Full implementation would search AST for definition
        nil
      end

      def format_hover(type_info)
        case type_info
        when String
          { language: 'milk-tea', value: type_info }
        else
          { language: 'milk-tea', value: type_info.to_s }
        end
      end

      def format_symbol(sym, uri)
        {
          name: sym[:name],
          kind: symbol_kind(sym[:kind]),
          location: {
            uri: uri,
            range: {
              start: { line: sym[:line].to_i - 1, character: 0 },
              end: { line: sym[:line].to_i, character: 0 }
            }
          }
        }
      end

      def symbol_kind(kind)
        case kind
        when 'function' then 6
        when 'struct' then 5
        when 'union' then 5
        when 'variant' then 22
        else 1
        end
      end
    end
  end
end
