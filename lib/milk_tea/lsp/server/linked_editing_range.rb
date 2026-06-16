# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerLinkedEditingRange
        private

        def handle_linked_editing_range(params)
          uri = params.dig("textDocument", "uri")
          lsp_line = params.dig("position", "line")
          lsp_char = params.dig("position", "character")
          return nil unless uri && lsp_line && lsp_char

          token = @workspace.find_token_at(uri, lsp_line, lsp_char)
          return nil unless token&.type == :identifier

          facts = @workspace.get_facts(uri)
          return nil unless facts

          binding_id = rename_target_binding_id(uri, token, lsp_line, lsp_char, facts)
          return nil unless binding_id
          return nil unless local_binding_id?(uri, facts, binding_id)

          ranges = scoped_binding_occurrence_ranges(uri, token.lexeme, facts, binding_id, include_declaration: true)
          return nil if ranges.empty?

          {
            ranges: ranges.map do |r|
              {
                start: { line: r[:line] - 1, character: r[:column] - 1 },
                end: { line: r[:line] - 1, character: r[:column] - 1 + r[:length] },
              }
            end,
          }
        rescue StandardError => e
          warn "Error in linkedEditingRange handler: #{e.message}"
          nil
        end
      end
    end
  end
end
