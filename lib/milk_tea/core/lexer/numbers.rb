# frozen_string_literal: true

module MilkTea
  class Lexer
    # Integer and float literal lexing, including type suffixes and exponents.
    module Numbers
      private

      def lex_number(line, index, line_number, line_offset:)
        start = index
        type = :integer

        if line[index] == "0" && %w[x X b B].include?(line[index + 1])
          base_char = line[index + 1]
          index += 2
          allowed = base_char.downcase == "x" ? HEX_DIGIT_BYTE : BIN_DIGIT_BYTE
          while index < line.length && (byte = line.getbyte(index)) && allowed[byte]
            index += 1
          end
        else
          while index < line.length && (byte = line.getbyte(index)) && NUMERIC_PART_BYTE[byte]
            index += 1
          end

          if line[index] == "." && digit?(line[index + 1])
            type = :float
            index += 1
            while index < line.length && (byte = line.getbyte(index)) && NUMERIC_PART_BYTE[byte]
              index += 1
            end
          end

          if exponent_part?(line, index)
            type = :float
            index += 1
            index += 1 if %w[+ -].include?(line[index])
            while index < line.length && (byte = line.getbyte(index)) && NUMERIC_PART_BYTE[byte]
              index += 1
            end
          end
        end

        int_suffix = nil
        if type == :integer
          int_suffix = scan_integer_suffix_at(line, index)
          index += int_suffix.length if int_suffix
        end

        if type == :float && line[index] == "f" && !identifier_part?((line[index + 1] || " ").to_s)
          index += 1
        elsif type == :float && line[index] == "d" && !identifier_part?((line[index + 1] || " ").to_s)
          index += 1
        end

        lexeme = line[start...index]
        if type == :integer
          cleaned = int_suffix ? lexeme.delete_suffix(int_suffix).delete("_") : lexeme.delete("_")
          literal = parse_integer(cleaned)
        else
          normalized = lexeme.delete("_").delete_suffix("f").delete_suffix("d")
          literal = normalized.to_f
        end
        @tokens << token(type, lexeme, literal, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index)
        index
      end

      def scan_integer_suffix_at(line, index)
        return nil if index >= line.length

        INTEGER_SUFFIX_STRINGS.find do |suffix|
          line[index, suffix.length] == suffix && !identifier_part?((line[index + suffix.length] || " ").to_s)
        end
      end

      def exponent_part?(line, index)
        return false unless %w[e E].include?(line[index])

        exponent_index = index + 1
        exponent_index += 1 if %w[+ -].include?(line[exponent_index])
        digit?(line[exponent_index])
      end

      def parse_integer(lexeme)
        cleaned = lexeme.delete("_")
        case cleaned
        when /\A0[xX]/
          cleaned[2..].to_i(16)
        when /\A0[bB]/
          cleaned[2..].to_i(2)
        else
          cleaned.to_i(10)
        end
      end
    end
  end
end
