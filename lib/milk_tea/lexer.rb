# frozen_string_literal: true

module MilkTea
  class LexError < StandardError
    attr_reader :line, :column, :path

    def initialize(message, line:, column:, path: nil)
      @line = line
      @column = column
      @path = path

      location = [path, "#{line}:#{column}"].compact.join(":")
      super(location.empty? ? message : "#{message} at #{location}")
    end
  end

  class Lexer
    TWO_CHAR_TOKENS = {
      "->" => :arrow,
      "+=" => :plus_equal,
      "-=" => :minus_equal,
      "*=" => :star_equal,
      "/=" => :slash_equal,
      "==" => :equal_equal,
      "!=" => :bang_equal,
      "<=" => :less_equal,
      ">=" => :greater_equal,
    }.freeze

    ONE_CHAR_TOKENS = {
      ":" => :colon,
      "," => :comma,
      "." => :dot,
      "(" => :lparen,
      ")" => :rparen,
      "[" => :lbracket,
      "]" => :rbracket,
      "?" => :question,
      "=" => :equal,
      "+" => :plus,
      "-" => :minus,
      "*" => :star,
      "/" => :slash,
      "%" => :percent,
      "<" => :less,
      ">" => :greater,
    }.freeze

    def self.lex(source, path: nil)
      new(source, path: path).lex
    end

    def initialize(source, path: nil)
      @source = source.gsub(/\r\n?/, "\n")
      @path = path
      @tokens = []
      @indent_stack = [0]
      @grouping_depth = 0
      @line_count = @source.empty? ? 1 : @source.lines.count
    end

    def lex
      @source.each_line.with_index(1) do |raw_line, line_number|
        lex_line(raw_line.delete_suffix("\n"), line_number)
      end

      raise LexError.new("unclosed grouping delimiter", line: @line_count, column: 1, path: @path) unless @grouping_depth.zero?

      while @indent_stack.length > 1
        @indent_stack.pop
        @tokens << token(:dedent, "", nil, @line_count, 1)
      end

      @tokens << token(:eof, "", nil, @line_count + 1, 1)
      @tokens
    end

    private

    def lex_line(line, line_number)
      tab_index = line.index("\t")
      if tab_index
        raise LexError.new("tabs are not allowed; use 4 spaces for indentation", line: line_number, column: tab_index + 1, path: @path)
      end

      return if line.strip.empty? || line.lstrip.start_with?("#")

      index = leading_space_count(line)
      if @grouping_depth.zero?
        emit_indentation(index, line_number)
      end

      while index < line.length
        char = line[index]

        if char == " "
          index += 1
          next
        end

        break if char == "#"

        if char == "c" && line[index + 1] == '"'
          index = lex_string(line, index, line_number, cstring: true)
          next
        end

        if identifier_start?(char)
          index = lex_identifier(line, index, line_number)
          next
        end

        if digit?(char)
          index = lex_number(line, index, line_number)
          next
        end

        index = lex_symbol(line, index, line_number)
      end

      @tokens << token(:newline, "\n", nil, line_number, line.length + 1) if @grouping_depth.zero?
    end

    def emit_indentation(indent, line_number)
      if (indent % 4) != 0
        raise LexError.new("indentation must use multiples of 4 spaces", line: line_number, column: indent + 1, path: @path)
      end

      current_indent = @indent_stack.last
      if indent == current_indent
        return
      end

      if indent > current_indent
        if indent != current_indent + 4
          raise LexError.new("indentation may only increase by 4 spaces at a time", line: line_number, column: 1, path: @path)
        end

        @indent_stack << indent
        @tokens << token(:indent, "", nil, line_number, 1)
        return
      end

      while @indent_stack.last > indent
        @indent_stack.pop
        @tokens << token(:dedent, "", nil, line_number, 1)
      end

      return if @indent_stack.last == indent

      raise LexError.new("indentation does not match any open block", line: line_number, column: 1, path: @path)
    end

    def lex_identifier(line, index, line_number)
      start = index
      index += 1
      while index < line.length && identifier_part?(line[index])
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

      @tokens << token(type, lexeme, literal, line_number, start + 1)
      index
    end

    def lex_number(line, index, line_number)
      start = index
      type = :integer

      if line[index] == "0" && %w[x X b B].include?(line[index + 1])
        base_char = line[index + 1]
        index += 2
        allowed = base_char.downcase == "x" ? /[0-9a-fA-F_]/ : /[01_]/
        while index < line.length && line[index].match?(allowed)
          index += 1
        end
      else
        while index < line.length && numeric_part?(line[index])
          index += 1
        end

        if line[index] == "." && digit?(line[index + 1])
          type = :float
          index += 1
          while index < line.length && numeric_part?(line[index])
            index += 1
          end
        end
      end

      lexeme = line[start...index]
      literal = type == :integer ? parse_integer(lexeme) : lexeme.delete("_").to_f
      @tokens << token(type, lexeme, literal, line_number, start + 1)
      index
    end

    def lex_string(line, index, line_number, cstring: false)
      start = index
      index += cstring ? 2 : 1
      value = +""

      while index < line.length
        char = line[index]
        if char == '"'
          lexeme = line[start..index]
          @tokens << token(cstring ? :cstring : :string, lexeme, value, line_number, start + 1)
          return index + 1
        end

        if char == "\\"
          escape = line[index + 1]
          raise LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path) unless escape

          value << decode_escape(escape)
          index += 2
          next
        end

        value << char
        index += 1
      end

      raise LexError.new("unterminated string literal", line: line_number, column: start + 1, path: @path)
    end

    def lex_symbol(line, index, line_number)
      start = index
      lexeme = line[index, 2]
      if lexeme && TWO_CHAR_TOKENS.key?(lexeme)
        type = TWO_CHAR_TOKENS.fetch(lexeme)
        @tokens << token(type, lexeme, nil, line_number, start + 1)
        adjust_grouping_depth(type, line_number, start + 1)
        return index + 2
      end

      lexeme = line[index]
      type = ONE_CHAR_TOKENS[lexeme]
      unless type
        raise LexError.new("unexpected character #{lexeme.inspect}", line: line_number, column: start + 1, path: @path)
      end

      @tokens << token(type, lexeme, nil, line_number, start + 1)
      adjust_grouping_depth(type, line_number, start + 1)
      index + 1
    end

    def adjust_grouping_depth(type, line_number, column)
      case type
      when :lparen, :lbracket
        @grouping_depth += 1
      when :rparen, :rbracket
        @grouping_depth -= 1
        if @grouping_depth.negative?
          raise LexError.new("unexpected closing delimiter", line: line_number, column: column, path: @path)
        end
      end
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

    def decode_escape(char)
      case char
      when "n" then "\n"
      when "r" then "\r"
      when "t" then "\t"
      when '"' then '"'
      when "\\" then "\\"
      else char
      end
    end

    def leading_space_count(line)
      line[/\A */].length
    end

    def identifier_start?(char)
      char.match?(/[A-Za-z_]/)
    end

    def identifier_part?(char)
      char.match?(/[A-Za-z0-9_]/)
    end

    def digit?(char)
      char && char.match?(/[0-9]/)
    end

    def numeric_part?(char)
      char && char.match?(/[0-9_]/)
    end

    def token(type, lexeme, literal, line, column)
      Token.new(type:, lexeme:, literal:, line:, column:)
    end
  end
end
