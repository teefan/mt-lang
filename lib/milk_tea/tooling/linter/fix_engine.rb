# frozen_string_literal: true

module MilkTea
  class Linter
    FixEdit = Data.define(:start_line, :start_char, :end_line, :end_char, :new_text)

    module FixEngine
      module_function

      def edits_for_rule(code, lines, warning)
        case code
        when "prefer-let"             then prefer_let_edits(lines, warning)
        when "redundant-ignored-match-binding" then redundant_ignored_match_binding_edits(lines, warning)
        when "prefer-let-else"        then prefer_let_else_edits(lines, warning)
        when "prefer-var-else"        then prefer_var_else_edits(lines, warning)
        when "redundant-bool-compare" then redundant_bool_compare_edits(lines, warning)
        when "redundant-cast"        then redundant_cast_edits(lines, warning)
        when "redundant-else"         then redundant_else_edits(lines, warning)
        when "redundant-return"       then redundant_return_edits(lines, warning)
        when "redundant-type-annotation" then redundant_type_annotation_edits(lines, warning)
        when "unused-import"          then unused_import_edits(lines, warning)
        when "trailing-list-comma"    then trailing_list_comma_edits(lines, warning)
        else []
        end
      end

      def apply_fix_edits(lines, edits)
        edits.sort_by { |e| [-e.start_line, -e.start_char] }.reverse_each do |edit|
          if edit.start_line == edit.end_line
            line = lines[edit.start_line]
            next unless line

            lines[edit.start_line] = +"#{line[0...edit.start_char]}#{edit.new_text}#{line[edit.end_char..]}"
          else
            prefix = (l = lines[edit.start_line]) ? l[0...edit.start_char] : ""
            suffix = (l = lines[edit.end_line]) ? l[edit.end_char..] : ""
            lines[edit.start_line..edit.end_line] = ["#{prefix}#{edit.new_text}#{suffix}"]
          end
        end
        lines
      end

      def edits_to_lsp_text_edits(edits, uri)
        edits.map do |edit|
          {
            range: {
              start: { line: edit.start_line, character: edit.start_char },
              end:   { line: edit.end_line,   character: edit.end_char },
            },
            newText: edit.new_text,
          }
        end
      end

      # ── per-rule edit generators ──────────────────────────────────────────

      def prefer_let_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        original = lines[line_idx]
        return [] unless original&.match?(/\bvar\b/)

        new_line = original.sub(/\bvar\b/, "let")
        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: new_line)]
      end

      def redundant_ignored_match_binding_edits(lines, warning)
        return [] unless warning.line && warning.column

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        span = Linter.redundant_ignored_match_binding_span(line, column: warning.column)
        return [] unless span

        [FixEdit.new(start_line: line_idx, start_char: span[:start_char], end_line: line_idx, end_char: span[:end_char], new_text: "")]
      end

      def prefer_let_else_edits(lines, warning)
        return [] unless warning.line

        fix = Linter.build_prefer_let_else_fix(lines, warning.line - 1, symbol_name: warning.symbol_name)
        return [] unless fix

        [FixEdit.new(start_line: fix[:start_line_idx], start_char: 0, end_line: fix[:end_line_idx] + 1, end_char: 0, new_text: fix[:new_text])]
      end

      def prefer_var_else_edits(lines, warning)
        prefer_let_else_edits(lines, warning)
      end

      def redundant_bool_compare_edits(lines, warning)
        return [] unless warning.line && warning.column && warning.length

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        start_char = warning.column - 1
        end_char = start_char + warning.length
        return [] if start_char.negative? || end_char > line.length

        expr_text = line[start_char...end_char]
        replacement = Linter.redundant_bool_compare_replacement(expr_text)
        return [] unless replacement

        [FixEdit.new(start_line: line_idx, start_char:, end_line: line_idx, end_char:, new_text: replacement)]
      end

      def redundant_else_edits(lines, warning)
        return [] unless warning.line

        diag_idx = warning.line - 1
        return [] if diag_idx.negative?

        if lines[diag_idx]&.match?(/\A\s*else:\s*\z/)
          else_idx = diag_idx
          first_body_idx = else_idx + 1
        else
          first_body_idx = diag_idx
          return [] if first_body_idx < 1

          else_idx = (0...first_body_idx).to_a.reverse.find { |i| lines[i]&.match?(/\A\s*else:\s*\z/) }
        end
        return [] unless else_idx
        return [] if first_body_idx >= lines.length

        else_indent = lines[else_idx].match(/\A(\s*)/)[1]
        body_indent = "#{else_indent}    "

        body_end_idx = first_body_idx
        (first_body_idx...lines.length).each do |i|
          l = lines[i]
          if l.chomp.empty? || l.start_with?(body_indent)
            body_end_idx = i
          else
            break
          end
        end

        new_body = lines[first_body_idx..body_end_idx].map { |l| l.sub(/\A    /, "") }.join
        [FixEdit.new(start_line: else_idx, start_char: 0, end_line: body_end_idx + 1, end_char: 0, new_text: new_body)]
      end

      def redundant_return_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        return [] unless lines[line_idx]&.match?(/\A\s*return\s*\z/)

        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: "")]
      end

      def unused_import_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        return [] unless lines[line_idx]&.match?(/\A\s*import\b/)

        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: "")]
      end

      def trailing_list_comma_edits(lines, warning)
        return [] unless warning.line && warning.column

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        char_idx = warning.column - 1
        return [] if char_idx.negative? || char_idx >= line.length
        return [] unless line[char_idx] == ","

        [FixEdit.new(start_line: line_idx, start_char: char_idx, end_line: line_idx, end_char: char_idx + 1, new_text: "")]
      end

      def redundant_type_annotation_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        name_len = warning.length
        col = warning.column - 1
        return [] if col.negative? || col + name_len > line.length

        after_name = col + name_len
        rest = line[after_name..]
        return [] unless rest

        type_match = rest.match(/\s*:\s*\S+/)
        return [] unless type_match

        new_line = +"#{line[0...after_name]}#{rest[type_match.end(0)..]}"
        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: new_line)]
      end

      def redundant_cast_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line
        return [] unless warning.column

        # Search for the cast pattern TypeName<-(...) starting at or before the column
        col = warning.column - 1
        # Also try searching from the beginning of the line
        cast_match = line.match(/(\w+)\s*<-\s*\((.+)\)/)
        return [] unless cast_match

        match_start = cast_match.begin(0)
        inner_expr = cast_match[2]
        full_len = cast_match.end(0) - match_start

        new_line = +"#{line[0...match_start]}#{inner_expr}#{line[(match_start + full_len)..]}"
        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: new_line)]
      end
    end
  end
end
