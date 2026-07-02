# frozen_string_literal: true

module MilkTea
  class Lexer
    # Format string lexing (`f"...#{expr}..."`) and the interpolation
    # scanning / format-spec splitting shared with format heredocs.
    module FormatStrings
      private

      def parse_format_heredoc_parts(content, start_line:, start_column:)
        parts = []
        text = +""
        index = 0
        line = start_line
        column = start_column
        base_column = start_column

        while index < content.length
          char = content[index]
          if char == "#" && content[index + 1] == "{"
            parts << { kind: :text, value: text } unless text.empty?
            text = +""

            expr_start = index + 2
            expr_line = line
            expr_column = column + 2
            expr_end = scan_format_interpolation_end(content, expr_start, expr_line, expr_column, recover: @recovery_errors)
            raw_source = content[expr_start...expr_end]
            if raw_source.strip.empty?
              raise LexError.new("empty format interpolation", line: line, column:, path: @path)
            end

            source, format_spec = split_format_interpolation_source(raw_source)
            parts << { kind: :expr, source:, format_spec:, line: expr_line, column: expr_column }

            while index <= expr_end
              line, column = advance_heredoc_position(char: content[index], line:, column:, base_column:)
              index += 1
            end
            next
          end

          text << char
          line, column = advance_heredoc_position(char:, line:, column:, base_column:)
          index += 1
        end

        parts << { kind: :text, value: text } unless text.empty?
        parts
      end

      def advance_heredoc_position(char:, line:, column:, base_column:)
        if char == "\n"
          [line + 1, base_column]
        else
          [line, column + 1]
        end
      end

      def lex_format_string(line, index, line_number, line_offset:)
        start = index
        index += 2
        text = +""
        parts = []

        while index < line.length
          char = line[index]
          if char == '"'
            parts << { kind: :text, value: text } unless text.empty?
            lexeme = line[start..index]
            @tokens << token(:fstring, lexeme, parts, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index + 1)
            return index + 1
          end

          if char == "#" && line[index + 1] == "{"
            parts << { kind: :text, value: text } unless text.empty?
            text = +""
            expr_start = index + 2
            expr_end = scan_format_interpolation_end(line, expr_start, line_number, start + 1, recover: @recovery_errors)
            raw_source = line[expr_start...expr_end]
            if raw_source.strip.empty?
              raise LexError.new("empty format interpolation", line: line_number, column: index + 1, path: @path)
            end

            source, format_spec = split_format_interpolation_source(raw_source)
            parts << { kind: :expr, source:, format_spec:, line: line_number, column: expr_start + 1 }
            index = expr_end + 1
            next
          end

          if char == "\\"
            next_char = line[index + 1]
            raise LexError.new("unterminated format string literal", line: line_number, column: start + 1, path: @path) unless next_char

            text << decode_escape(next_char)
            index += 2
            next
          end

          text << char
          index += 1
        end

        if @recovery_errors
          @recovery_errors << LexError.new("unterminated format string literal", line: line_number, column: start + 1, path: @path)
          parts << { kind: :text, value: text } unless text.empty?
          lexeme = line[start..]
          @tokens << token(:fstring, lexeme, parts, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + line.length)
          return line.length
        end

        raise LexError.new("unterminated format string literal", line: line_number, column: start + 1, path: @path)
      end

      def scan_format_interpolation_end(line, index, line_number, column, recover: false)
        depth = 1

        while index < line.length
          char = line[index]

          if char == '"'
            index = skip_string_contents(line, index, line_number)
            next
          end

          if char == "{"
            depth += 1
            index += 1
            next
          end

          if char == "}"
            depth -= 1
            return index if depth == 0

            index += 1
            next
          end

          index += 1
        end

        if recover
          @recovery_errors << LexError.new("unterminated format interpolation", line: line_number, column:, path: @path) if @recovery_errors
          return line.length
        end

        raise LexError.new("unterminated format interpolation", line: line_number, column:, path: @path)
      end

      def skip_string_contents(line, index, line_number)
        index += 1

        while index < line.length
          char = line[index]
          return index + 1 if char == '"'

          if char == "\\"
            raise LexError.new("unterminated string literal", line: line_number, column: index + 1, path: @path) unless line[index + 1]

            index += 2
            next
          end

          index += 1
        end

        raise LexError.new("unterminated string literal", line: line_number, column: index + 1, path: @path)
      end

      def split_format_interpolation_source(source)
        depth = 0
        format_spec_index = nil
        index = 0

        while index < source.length
          char = source[index]

          if char == '"'
            index = skip_interpolation_string_contents(source, index)
            next
          end

          case char
          when "(", "[", "{"
            depth += 1
          when ")", "]", "}"
            depth -= 1 if depth.positive?
          when ":"
            suffix = source[(index + 1)..]
            format_spec_index = index if depth.zero? && format_spec_suffix?(suffix)
          end

          index += 1
        end

        return [source, nil] unless format_spec_index

        [source[0...format_spec_index], source[(format_spec_index + 1)..]]
      end

      def skip_interpolation_string_contents(source, index)
        index += 1

        while index < source.length
          char = source[index]
          return index + 1 if char == '"'

          if char == "\\"
            index += 2
            next
          end

          index += 1
        end

        source.length
      end

      def format_spec_suffix?(source)
        source && source.strip.match?(/\A(?:\.\d+|[xXoObB])\z/)
      end
    end
  end
end
