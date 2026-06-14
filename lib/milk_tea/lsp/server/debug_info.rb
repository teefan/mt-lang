# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerDebugInfo
        private

        def handle_debug_info(params)
          uri = params.dig('textDocument', 'uri')
          return { text: 'error: no textDocument.uri' } unless uri

          content = @workspace.get_content(uri)
          path = uri_to_path(uri) || uri
          tokens = @workspace.get_tokens(uri)
          ast = @workspace.get_ast(uri)
          facts = @workspace.get_facts(uri)
          snapshot = @workspace.get_tooling_snapshot(uri)

          parse_errors = begin
            result = MilkTea::Parser.parse_collecting_errors(content, path: uri)
            result.errors
          rescue StandardError
            []
          end

          text = DebugInfoFormatter.format_all(
            content: content,
            tokens: tokens,
            ast: ast,
            parse_errors: parse_errors,
            facts: facts,
            snapshot: snapshot,
            path: path,
          )

          { text: text }
        rescue StandardError => e
          { text: "error generating debug info: #{e.message}\n#{e.backtrace.first(5).join("\n")}" }
        end
      end
    end
  end
end
