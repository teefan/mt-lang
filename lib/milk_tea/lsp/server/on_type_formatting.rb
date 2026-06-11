# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerOnTypeFormatting
        private

        BLOCK_INTRODUCING_KEYWORDS = %w[function async editable public
          struct enum flags variant union
          interface if elif else while for match unsafe extending defer when].freeze

        def handle_on_type_formatting(params)
          ch = params["ch"]
          return [] unless ch == "\n"

          uri = params["textDocument"]["uri"]
          position = params["position"]
          lsp_line = position["line"]
          lsp_char = position["character"]

          content = @workspace.get_content(uri)
          return [] unless content

          lines = content.split("\n", -1)
          return [] if lsp_line <= 0 || lsp_line >= lines.length

          prev_line = lines[lsp_line - 1] || ""
          prev_stripped = prev_line.lstrip
          return [] if prev_stripped.empty?

          prev_indent = prev_line.length - prev_stripped.length

          indent = prev_indent
          if prev_stripped.end_with?(":")
            first_word = prev_stripped.split(/\s+/).first.to_s
            if BLOCK_INTRODUCING_KEYWORDS.include?(first_word)
              indent = prev_indent + 4
            end
          end

          current_indent = (lines[lsp_line] || "").length - (lines[lsp_line] || "").lstrip.length
          return [] if indent == current_indent

          new_text = " " * indent
          [{
            range: {
              start: { line: lsp_line, character: 0 },
              end: { line: lsp_line, character: current_indent },
            },
            newText: new_text,
          }]
        end
      end
    end
  end
end
