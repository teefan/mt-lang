# frozen_string_literal: true

module MilkTea
  module LSP
    class Server
      module ServerFoldingRange
        private

        BLOCK_START_PATTERN = /\A(public\s+)?(async\s+)?(editable\s+)?(function|struct|enum|flags|variant|union|interface|if|while|for|match|unsafe|extending|defer)\b/

        CONTINUATION_KEYWORDS = %w[else elif when].freeze

        def handle_folding_range(params)
          text_document = params["textDocument"]
          uri = text_document["uri"]
          content = @workspace.get_content(uri)
          return [] unless content

          lines = content.split("\n", -1)
          folds = []

          compute_block_folds(lines, folds)
          compute_import_folds(lines, folds)
          compute_comment_folds(lines, folds)
          trim_trailing_blank_lines(folds, lines)

          folds
        end

        private

        def compute_block_folds(lines, folds)
          stack = [] # [[start_line, indent], ...]
          last_indent = 0

          lines.each_with_index do |line, line_num|
            stripped = line.lstrip
            next if stripped.empty?

            indent = line.length - stripped.length
            stripped_no_comment = strip_comment(stripped)

            if indent < last_indent
              while stack.any? && stack.last[1] >= indent
                start_line, = stack.pop
                folds << folding_range(start_line, line_num - 1) if line_num - 1 > start_line
              end
            end

            if continuation_start?(stripped_no_comment)
              if stack.any? && stack.last[1] == indent
                start_line, = stack.pop
                folds << folding_range(start_line, line_num - 1) if line_num - 1 > start_line
              end
              stack << [line_num, indent]
            elsif block_start?(stripped_no_comment)
              stack << [line_num, indent]
            end

            last_indent = indent
          end

          last_line = lines.length - 1
          while stack.any?
            start_line, = stack.pop
            folds << folding_range(start_line, last_line) if last_line > start_line
          end
        end

        def compute_import_folds(lines, folds)
          import_start = nil

          lines.each_with_index do |line, line_num|
            stripped = line.lstrip
            if stripped.start_with?("import ")
              import_start ||= line_num
            else
              if import_start && line_num - 1 > import_start
                folds << {
                  startLine: import_start,
                  endLine: line_num - 1,
                  kind: "imports",
                }
              end
              import_start = nil
            end
          end

          return unless import_start

          last_line = lines.length - 1
          return unless last_line > import_start

          folds << {
            startLine: import_start,
            endLine: last_line,
            kind: "imports",
          }
        end

        def compute_comment_folds(lines, folds)
          comment_start = nil

          lines.each_with_index do |line, line_num|
            stripped = line.lstrip
            if stripped.start_with?("#>") && comment_start.nil?
              comment_start = line_num
            elsif stripped.include?("<#") && comment_start
              folds << {
                startLine: comment_start,
                endLine: line_num,
                kind: "comment",
              }
              comment_start = nil
            end
          end
        end

        def block_start?(stripped)
          return false unless stripped.end_with?(":") || stripped == ":"

          stripped.match?(BLOCK_START_PATTERN) && !CONTINUATION_KEYWORDS.any? { |kw| stripped.start_with?(kw) }
        end

        def continuation_start?(stripped)
          return false unless stripped.end_with?(":") || stripped == ":"

          CONTINUATION_KEYWORDS.any? { |kw| stripped.start_with?(kw) }
        end

        def strip_comment(line)

          idx = line.index(" #")
          idx ? line[0...idx] : line
        end

        def trim_trailing_blank_lines(folds, lines)
          folds.each do |fold|
            end_line = fold[:endLine]
            while end_line > fold[:startLine] && lines[end_line].strip.empty?
              end_line -= 1
            end
            fold[:endLine] = end_line
          end
        end

        def folding_range(start_line, end_line)
          { startLine: start_line, endLine: end_line }
        end
      end
    end
  end
end
