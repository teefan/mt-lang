# frozen_string_literal: true

module MilkTea
  class Lexer
    # Identifier lexing plus the raw-byte character-classification helpers.
    module CharacterClasses
      private

      def lex_identifier(line, index, line_number, line_offset:)
        start = index
        length = line.length
        index += 1
        while index < length && (byte = line.getbyte(index)) && IDENT_PART_BYTE[byte]
          index += 1
        end

        lexeme = line[start...index]
        type = Token::KEYWORDS.fetch(lexeme, :identifier)
        literal = case type
                  when :true then true
                  when :false then false
                  when :null then nil
                  else nil
                  end

        @tokens << token(type, lexeme, literal, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index)
        index
      end

      def leading_space_count(line)
        index = 0
        index += 1 while line.getbyte(index) == SPACE_BYTE
        index
      end

      def identifier_start?(char)
        byte = char && char.getbyte(0)
        byte ? IDENT_START_BYTE[byte] : false
      end

      def identifier_part?(char)
        byte = char && char.getbyte(0)
        byte ? IDENT_PART_BYTE[byte] : false
      end

      def identifier_start_token(line, start_index)
        return "" unless start_index < line.length && identifier_start?(line[start_index])

        finish = start_index + 1
        finish += 1 while finish < line.length && identifier_part?(line[finish])
        line[start_index...finish]
      end

      def digit?(char)
        byte = char && char.getbyte(0)
        byte ? DIGIT_BYTE[byte] : false
      end
    end
  end
end
