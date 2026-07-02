# frozen_string_literal: true

module MilkTea
  class Lexer
    # String literal lexing (including adjacent-literal continuation),
    # character literal lexing, and escape-sequence decoding.
    module Strings
      private

      def lex_string(lines, line_index, line, index, line_number, line_offset:, cstring: false)
        segment = scan_string_segment(line, index, line_number, cstring:, recover: @recovery_errors)
        consumed_lines = 1
        value = +segment.value
        last_line = line
        last_line_number = line_number
        last_line_offset = line_offset
        last_segment_end = segment.next_index
        last_line_has_newline = lines.fetch(line_index).end_with?("\n")
        remainder = line[segment.next_index..] || ""
        line_indent = leading_space_count(line)
        recovered = segment.recovered

        if remainder.strip.empty? && !recovered
          scan_line_index = line_index + 1
          scan_line_number = line_number + 1
          scan_line_offset = line_offset + lines.fetch(line_index).bytesize

          while scan_line_index < lines.length
            raw_line = lines.fetch(scan_line_index)
            scan_line = raw_line.delete_suffix("\n").b
            segment_start = leading_space_count(scan_line)
            prefix = cstring ? 'c"' : '"'

            break unless segment_start > line_indent
            break if scan_line[segment_start].nil?
            break if scan_line[segment_start] == "#"
            break unless scan_line[segment_start, prefix.length] == prefix

            continued_segment = scan_string_segment(scan_line, segment_start, scan_line_number, cstring:, recover: @recovery_errors)
            continued_remainder = scan_line[continued_segment.next_index..] || ""
            break unless continued_remainder.strip.empty?

            value << continued_segment.value
            consumed_lines += 1
            last_line = scan_line
            last_line_number = scan_line_number
            last_line_offset = scan_line_offset
            last_segment_end = continued_segment.next_index
            last_line_has_newline = raw_line.end_with?("\n")
            recovered ||= continued_segment.recovered

            scan_line_offset += raw_line.bytesize
            scan_line_number += 1
            scan_line_index += 1

            break if continued_segment.recovered
          end
        end

        start_offset = line_offset + index
        if consumed_lines == 1
          lexeme = line[index...segment.next_index]
          @tokens << token(cstring ? :cstring : :string, lexeme, value, line_number, index + 1, start_offset:, end_offset: line_offset + segment.next_index)
          return StringLexResult.new(consumed_lines:, next_index: segment.next_index)
        end

        end_offset = last_line_offset + last_segment_end
        lexeme = @source.byteslice(start_offset, end_offset - start_offset)
        @tokens << token(cstring ? :cstring : :string, lexeme, value, line_number, index + 1, start_offset:, end_offset:)
        emit_line_newline(last_line, last_line_number, last_line_offset, last_line_has_newline)
        StringLexResult.new(consumed_lines:, next_index: last_segment_end)
      end

      def scan_string_segment(line, index, line_number, cstring: false, recover: false)
        start = index
        index += cstring ? 2 : 1
        value = +""

        while index < line.length
          char = line[index]
          if char == '"'
            return StringSegment.new(next_index: index + 1, value:)
          end

          if char == "\\"
            escape = line[index + 1]
            if escape.nil?
              if recover
                @recovery_errors << LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path) if @recovery_errors
                return StringSegment.new(next_index: line.length, value:, recovered: true)
              end

              raise LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path)
            end

            value << decode_escape(escape)
            index += 2
            next
          end

          value << char
          index += 1
        end

        if recover
          @recovery_errors << LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path) if @recovery_errors
          return StringSegment.new(next_index: line.length, value:, recovered: true)
        end

        raise LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path)
      end

      def lex_char_literal(line, index, line_number, line_offset:)
        start = index
        index += 1
        if index >= line.length
          raise LexError.new("unterminated character literal", line: line_number, column: start + 1, path: @path)
        end

        char = line[index]
        if char == "\\"
          index += 1
          if index >= line.length
            raise LexError.new("unterminated escape in character literal", line: line_number, column: start + 1, path: @path)
          end
          escape_char = line[index]
          if escape_char == "x"
            hex = line[index + 1, 2]
            unless hex&.match?(/\A[0-9a-fA-F]{2}\z/)
              raise LexError.new("invalid hex escape in character literal", line: line_number, column: index + 1, path: @path)
            end
            value = hex.to_i(16)
            index += 3
          else
            value = decode_escape(escape_char).ord
            index += 1
          end
        else
          value = char.ord
          index += 1
        end

        if index >= line.length || line[index] != "'"
          raise LexError.new("expected closing ' in character literal", line: line_number, column: index + 1, path: @path)
        end
        index += 1

        lexeme = line[start...index]
        @tokens << token(:char_literal, lexeme, value, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index)
        index
      end

      def decode_escape(char)
        case char
        when "n" then "\n"
        when "r" then "\r"
        when "t" then "\t"
        when "0" then "\0"
        when '"' then '"'
        when "'" then "'"
        when "\\" then "\\"
        else char
        end
      end
    end
  end
end
