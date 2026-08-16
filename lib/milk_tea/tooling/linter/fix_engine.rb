# frozen_string_literal: true

module MilkTea
  class Linter
    FixEdit = Data.define(:start_line, :start_char, :end_line, :end_char, :new_text)

    module FixEngine

      def self.edits_for_rule(code, lines, warning)
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
        when "prefer-inline-methods"  then prefer_inline_methods_edits(lines, warning)
        when "unused-import"          then unused_import_edits(lines, warning)
        when "trailing-list-comma"    then trailing_list_comma_edits(lines, warning)
        else []
        end
      end

      def self.apply_fix_edits(lines, edits)
        edits.sort_by { |e| [-e.start_line, -e.start_char] }.each do |edit|
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

      def self.edits_to_lsp_text_edits(edits, uri)
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

      def self.prefer_let_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        original = lines[line_idx]
        return [] unless original&.match?(/\bvar\b/)

        new_line = original.sub(/\bvar\b/, "let")
        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: new_line)]
      end

      def self.redundant_ignored_match_binding_edits(lines, warning)
        return [] unless warning.line && warning.column

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        span = Linter.redundant_ignored_match_binding_span(line, column: warning.column)
        return [] unless span

        [FixEdit.new(start_line: line_idx, start_char: span[:start_char], end_line: line_idx, end_char: span[:end_char], new_text: "")]
      end

      def self.prefer_let_else_edits(lines, warning)
        return [] unless warning.line

        fix = Linter.build_prefer_let_else_fix(lines, warning.line - 1, symbol_name: warning.symbol_name)
        return [] unless fix

        [FixEdit.new(start_line: fix[:start_line_idx], start_char: 0, end_line: fix[:end_line_idx] + 1, end_char: 0, new_text: fix[:new_text])]
      end

      def self.prefer_var_else_edits(lines, warning)
        prefer_let_else_edits(lines, warning)
      end

      def self.redundant_bool_compare_edits(lines, warning)
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

      def self.redundant_else_edits(lines, warning)
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

      def self.redundant_return_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        return [] unless lines[line_idx]&.match?(/\A\s*return\s*\z/)

        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: "")]
      end

      # Moves the methods of an `extending X:` block inline into the matching
      # `struct X:` declaration. Only rewrites when the struct immediately
      # precedes the extending block (blank lines allowed between them); other
      # layouts are left alone since the move would be non-local.
      def self.prefer_inline_methods_edits(lines, warning)
        name = warning.symbol_name
        return [] unless name && warning.line

        struct_idx = lines.index { |l| l.match?(/\A\s*struct\s+#{Regexp.escape(name)}\b/) }
        return [] unless struct_idx

        last_member_idx = nil
        ((struct_idx + 1)...lines.length).each do |i|
          l = lines[i]
          break if !l.chomp.empty? && !l.start_with?(" ", "\t")

          last_member_idx = i unless l.chomp.empty?
        end
        return [] unless last_member_idx

        ext_start_idx = warning.line - 1
        return [] unless last_member_idx < ext_start_idx

        ext_end_idx = ext_start_idx
        ((ext_start_idx + 1)...lines.length).each do |i|
          l = lines[i]
          break if !l.chomp.empty? && !l.start_with?(" ", "\t")

          ext_end_idx = i unless l.chomp.empty?
        end

        method_lines = lines[(ext_start_idx + 1)..ext_end_idx].to_a
        method_lines.shift while method_lines.first && method_lines.first.chomp.empty?
        method_lines.pop while method_lines.last && method_lines.last.chomp.empty?
        return [] if method_lines.empty?

        between = lines[(last_member_idx + 1)...ext_start_idx]
        return [] unless between.all? { |l| l.chomp.empty? }

        method_text = method_lines.join
        new_text = "#{lines[last_member_idx].chomp}\n\n#{method_text}"

        [FixEdit.new(start_line: last_member_idx, start_char: 0, end_line: ext_end_idx + 1, end_char: 0, new_text: new_text)]
      end

      def self.unused_import_edits(lines, warning)
        return [] unless warning.line

        line_idx = warning.line - 1
        return [] unless lines[line_idx]&.match?(/\A\s*import\b/)

        [FixEdit.new(start_line: line_idx, start_char: 0, end_line: line_idx + 1, end_char: 0, new_text: "")]
      end

      def self.trailing_list_comma_edits(lines, warning)
        return [] unless warning.line && warning.column

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        char_idx = warning.column - 1
        return [] if char_idx.negative? || char_idx >= line.length
        return [] unless line[char_idx] == ","

        [FixEdit.new(start_line: line_idx, start_char: char_idx, end_line: line_idx, end_char: char_idx + 1, new_text: "")]
      end

      def self.redundant_type_annotation_edits(lines, warning)
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

      def self.redundant_cast_edits(lines, warning)
        return [] unless warning.line && warning.column

        line_idx = warning.line - 1
        line = lines[line_idx]
        return [] unless line

        start = warning.column - 1
        return [] unless start >= 0 && start < line.length

        arrow = line.index("<-", start)
        return [] unless arrow

        type_ref = line[start...arrow]
        return [] unless type_ref.match?(/\A[A-Za-z_][A-Za-z0-9_\[\]\.,\s@]*\z/)

        arrow_end = arrow + 2

        # When only the parentheses are redundant (the cast itself is still
        # needed), remove just the `(` and matching `)`.
        if warning.message&.include?("parentheses")
          return [] unless arrow_end < line.length && line[arrow_end] == "("

          open_paren = arrow_end
          close_paren = match_paren(line, open_paren)
          return [] unless close_paren

          return [FixEdit.new(start_line: line_idx, start_char: open_paren, end_line: line_idx, end_char: open_paren + 1, new_text: ""),
                  FixEdit.new(start_line: line_idx, start_char: close_paren, end_line: line_idx, end_char: close_paren + 1, new_text: "")]
        end

        # Cast to same type / own->ptr / widening are redundant — remove the
        # `TargetType<-` prefix. When the inner expression is then left
        # parenthesized with no operators, also strip the orphaned parens.
        new_start = start

        # When the cast is inside an `unsafe:` expression, also remove the
        # `unsafe: ` wrapper.
        unsafe_keyword = line.rindex("unsafe:", new_start)
        if unsafe_keyword
          prefix = line[unsafe_keyword...new_start]
          if prefix.match?(/\Aunsafe:\s*\z/)
            new_start = unsafe_keyword
          end
        end

        edits = [FixEdit.new(start_line: line_idx, start_char: new_start, end_line: line_idx, end_char: arrow_end, new_text: "")]

        if arrow_end < line.length && line[arrow_end] == "("
          close_paren = match_paren(line, arrow_end)
          if close_paren && !inner_has_top_level_operators?(line[arrow_end + 1...close_paren])
            edits << FixEdit.new(start_line: line_idx, start_char: arrow_end, end_line: line_idx, end_char: arrow_end + 1, new_text: "")
            edits << FixEdit.new(start_line: line_idx, start_char: close_paren, end_line: line_idx, end_char: close_paren + 1, new_text: "")
          end
        end

        edits
      end

      def self.match_paren(line, open_pos)
        depth = 0
        (open_pos...line.length).each do |i|
          case line[i]
          when "(" then depth += 1
          when ")" then depth -= 1; return i if depth == 0
          end
        end
        nil
      end

      BINARY_OP_CHARS = %w[+ - * / % & | ^ < > = ! ? :].freeze

      def self.inner_has_top_level_operators?(inner)
        depth = 0
        i = 0
        while i < inner.length
          case inner[i]
          when "(", "[", "{"
            depth += 1
          when ")", "]", "}"
            depth -= 1 if depth > 0
          when *BINARY_OP_CHARS
            if depth == 0 && (inner[i] == "-" || inner[i] == "~") && start_of_expression?(inner, i)
              i += 1
              next
            end
            return true if depth == 0
          end
          i += 1
        end
        false
      end

      def self.start_of_expression?(inner, pos)
        return true if pos == 0
        prev = pos - 1
        prev >= 0 && (inner[prev] == " " || inner[prev] == "\t" || inner[prev] == "(")
      end
    end
  end
end
