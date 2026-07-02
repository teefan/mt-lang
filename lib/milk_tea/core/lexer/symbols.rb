# frozen_string_literal: true

module MilkTea
  class Lexer
    # Operator / punctuation lexing and grouping-delimiter depth tracking.
    module Symbols
      private

      def lex_symbol(line, index, line_number, line_offset:)
        start = index
        lexeme = line[index, 3]
        if lexeme && THREE_CHAR_TOKENS.key?(lexeme)
          type = THREE_CHAR_TOKENS.fetch(lexeme)
          @tokens << token(type, lexeme, nil, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index + 3)
          return index + 3
        end

        lexeme = line[index, 2]
        if lexeme && TWO_CHAR_TOKENS.key?(lexeme)
          type = TWO_CHAR_TOKENS.fetch(lexeme)
          @tokens << token(type, lexeme, nil, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index + 2)
          adjust_grouping_depth(type, line_number, start + 1)
          return index + 2
        end

        lexeme = line[index]
        type = ONE_CHAR_TOKENS[lexeme]
        unless type
          if @recovery_errors && lexeme == "}"
            @recovery_errors << LexError.new("unexpected closing delimiter", line: line_number, column: start + 1, path: @path)
            return index + 1
          end

          if @recovery_errors
            @recovery_errors << LexError.new("unexpected character #{lexeme.inspect}", line: line_number, column: start + 1, path: @path)
            return index + 1
          end

          raise LexError.new("unexpected character #{lexeme.inspect}", line: line_number, column: start + 1, path: @path)
        end

        @tokens << token(type, lexeme, nil, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index + 1)
        adjust_grouping_depth(type, line_number, start + 1)
        index + 1
      end

      def adjust_grouping_depth(type, line_number, column)
        case type
        when :lparen, :lbracket
          if @grouping_depth.zero?
            @grouping_start_line = line_number
            @grouping_start_column = column
          end
          @grouping_depth += 1
        when :rparen, :rbracket
          @grouping_depth -= 1
          if @grouping_depth.negative?
            error = LexError.new("unexpected closing delimiter", line: line_number, column: column, path: @path)
            if @recovery_errors
              @recovery_errors << error
              @grouping_depth = 0
              return
            end

            raise error
          end
        end
      end
    end
  end
end
