# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerSelectionRange
        private

        def handle_selection_range(params)
          positions = params["positions"] || []
          uri = params["textDocument"]["uri"]

          content = @workspace.get_content(uri)
          return [] unless content

          lines = content.split("\n", -1)

          positions.map do |pos|
            line = pos["line"]
            char = pos["character"]
            build_selection_range(lines, line, char)
          end
        end

        private

        def build_selection_range(lines, lsp_line, lsp_char)
          line_str = lines[lsp_line] || ""
          return nil if line_str.empty?

          token_range = token_bounds_at(line_str, lsp_char)
          line_range = { start: { line: lsp_line, character: 0 },
                         end: { line: lsp_line, character: line_str.length } }

          current = {
            range: token_range || line_range,
          }

          current[:parent] = { range: line_range }

          statement_range = find_statement_range(lines, lsp_line)
          if statement_range
            current[:parent][:parent] = { range: statement_range }

            block_range = find_enclosing_block_range(lines, lsp_line)
            if block_range
              current[:parent][:parent][:parent] = { range: block_range }
            end
          end

          current
        end

        def token_bounds_at(line_str, lsp_char)
          col = [lsp_char, line_str.length - 1].min
          col = [col, 0].max

          return nil if line_str[col] == " " || line_str[col].nil?

          left = col
          left -= 1 while left > 0 && line_str[left - 1] =~ /[A-Za-z0-9_]/
          right = col
          right += 1 while right < line_str.length - 1 && line_str[right + 1] =~ /[A-Za-z0-9_]/

          return nil if left == right && line_str[left] !~ /[A-Za-z0-9_]/

          {
            start: { line: 0, character: left },
            end: { line: 0, character: right + 1 },
          }
        end

        def find_statement_range(lines, lsp_line)
          indent = (lines[lsp_line] || "").length - (lines[lsp_line] || "").lstrip.length

          start_line = lsp_line
          start_line -= 1 while start_line > 0 &&
            lines[start_line - 1].strip.empty? &&
            (lines[start_line - 1].length - lines[start_line - 1].lstrip.length) >= indent

          start_line -= 1 while start_line > 0 &&
            !lines[start_line - 1].strip.empty? &&
            (lines[start_line - 1].length - lines[start_line - 1].lstrip.length) >= indent

          end_line = lsp_line
          end_line += 1 while end_line < lines.length - 1 &&
            (lines[end_line + 1].strip.empty? ||
             (lines[end_line + 1].length - lines[end_line + 1].lstrip.length) > indent)

          return nil if start_line == end_line && lines[start_line].strip.empty?

          {
            start: { line: start_line, character: 0 },
            end: { line: end_line, character: (lines[end_line] || "").length },
          }
        end

        def find_enclosing_block_range(lines, lsp_line)
          indent = (lines[lsp_line] || "").length - (lines[lsp_line] || "").lstrip.length
          return nil if indent <= 0

          start_line = lsp_line
          start_line -= 1 while start_line > 0 &&
            ((lines[start_line - 1].strip.empty?) ||
             (lines[start_line - 1].length - lines[start_line - 1].lstrip.length) >= indent)

          while start_line > 0 &&
                (lines[start_line - 1].strip.empty? ||
                 (lines[start_line - 1].length - lines[start_line - 1].lstrip.length) >= indent)
            start_line -= 1
          end

          end_line = lsp_line
          while end_line < lines.length - 1 &&
                (lines[end_line + 1].strip.empty? ||
                 (lines[end_line + 1].length - lines[end_line + 1].lstrip.length) >= indent)
            end_line += 1
          end

          return nil if start_line == end_line

          {
            start: { line: start_line, character: 0 },
            end: { line: end_line, character: (lines[end_line] || "").length },
          }
        end
      end
    end
  end
end
