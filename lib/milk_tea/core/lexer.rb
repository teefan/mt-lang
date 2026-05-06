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
    LexResult = Data.define(:tokens, :trivia)
    StringLexResult = Data.define(:consumed_lines, :next_index)
    StringSegment = Data.define(:next_index, :value)

    LINE_CONTINUATION_OPERATORS = %i[
      plus minus star slash percent
      pipe amp caret
      or and
      equal_equal bang_equal
      less less_equal greater greater_equal
      shift_left shift_right
    ].freeze

    THREE_CHAR_TOKENS = {
      "..." => :ellipsis,
      "<<=" => :shift_left_equal,
      ">>=" => :shift_right_equal,
    }.freeze

    TWO_CHAR_TOKENS = {
      "->" => :arrow,
      ".." => :dot_dot,
      "<<" => :shift_left,
      ">>" => :shift_right,
      "+=" => :plus_equal,
      "-=" => :minus_equal,
      "*=" => :star_equal,
      "/=" => :slash_equal,
      "%=" => :percent_equal,
      "&=" => :amp_equal,
      "|=" => :pipe_equal,
      "^=" => :caret_equal,
      "==" => :equal_equal,
      "!=" => :bang_equal,
      "<=" => :less_equal,
      ">=" => :greater_equal,
    }.freeze

    ONE_CHAR_TOKENS = {
      "&" => :amp,
      ":" => :colon,
      "," => :comma,
      "^" => :caret,
      "." => :dot,
      "(" => :lparen,
      ")" => :rparen,
      "|" => :pipe,
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
      "~" => :tilde,
    }.freeze

    def self.lex(source, path: nil, mode: :syntax_only)
      result = new(source, path: path, mode:).lex
      mode == :with_trivia ? result.tokens : result
    end

    def self.lex_with_trivia(source, path: nil)
      new(source, path: path, mode: :with_trivia).lex
    end

    def initialize(source, path: nil, mode: :syntax_only)
      @source = source.gsub(/\r\n?/, "\n")
      @path = path
      @mode = mode
      @tokens = []
      @trivia = []
      @pending_leading_trivia = []
      @indent_stack = [0]
      @grouping_depth = 0
      @line_count = @source.empty? ? 1 : @source.lines.count
      @continuation_pending = false
    end

    def lex
      lines = @source.each_line.to_a
      line_offset = 0
      line_number = 1
      line_index = 0

      while line_index < lines.length
        raw_line = lines[line_index]
        has_newline = raw_line.end_with?("\n")
        # Use byte-indexed scanning so token offsets remain consistent for UTF-8 content.
        line = raw_line.delete_suffix("\n").b
        consumed_lines = lex_line(lines, line_index, line, line_number, line_offset, has_newline:)

        consumed_lines.times do |delta|
          line_offset += lines.fetch(line_index + delta).bytesize
        end
        line_number += consumed_lines
        line_index += consumed_lines
      end

      raise LexError.new("unclosed grouping delimiter", line: @line_count, column: 1, path: @path) unless @grouping_depth.zero?

      while @indent_stack.length > 1
        @indent_stack.pop
        @tokens << token(:dedent, "", nil, @line_count, 1, start_offset: @source.bytesize, end_offset: @source.bytesize)
      end

      @tokens << token(:eof, "", nil, @line_count + 1, 1, start_offset: @source.bytesize, end_offset: @source.bytesize)
      return LexResult.new(tokens: @tokens, trivia: @trivia) if with_trivia?

      @tokens
    end

    private

    def with_trivia?
      @mode == :with_trivia
    end

    def lex_line(lines, line_index, line, line_number, line_offset, has_newline:)
      tab_index = line.index("\t")
      if tab_index
        raise LexError.new("tabs are not allowed; use 4 spaces for indentation", line: line_number, column: tab_index + 1, path: @path)
      end

      if line.strip.empty?
        register_detached_line_trivia(:blank_line, line, line_number, line_offset, has_newline:)
        return 1
      end

      if line.lstrip.start_with?("#")
        register_detached_line_trivia(:comment, line, line_number, line_offset, has_newline:)
        return 1
      end

      index = leading_space_count(line)
      if with_trivia? && index.positive?
        push_pending_leading_trivia(
          TriviaToken.new(
            kind: :space,
            text: line[0...index],
            line: line_number,
            column: 1,
            start_offset: line_offset,
            end_offset: line_offset + index,
          ),
        )
      end

      if @grouping_depth.zero?
        emit_indentation(index, line_number, line_offset) unless @continuation_pending
      end
      @continuation_pending = false

      while index < line.length
        char = line[index]

        if char == " "
          if with_trivia?
            span_start = index
            index += 1 while index < line.length && line[index] == " "
            push_pending_leading_trivia(
              TriviaToken.new(
                kind: :space,
                text: line[span_start...index],
                line: line_number,
                column: span_start + 1,
                start_offset: line_offset + span_start,
                end_offset: line_offset + index,
              ),
            )
            next
          end

          index += 1
          next
        end

        if char == "#"
          if with_trivia?
            comment_end = line.length
            comment_text = line[index...comment_end]
            append_trailing_or_pending(
              TriviaToken.new(
                kind: :comment,
                text: comment_text,
                line: line_number,
                column: index + 1,
                start_offset: line_offset + index,
                end_offset: line_offset + comment_end,
              ),
            )
          end
          break
        end

        if char == "c" && heredoc_start?(line, index, cstring: true)
          return lex_heredoc(lines, line_index, index, line_number, line_offset, cstring: true)
        end

        if char == "c" && line[index + 1] == '"'
          result = lex_string(lines, line_index, line, index, line_number, line_offset:, cstring: true)
          return result.consumed_lines if result.consumed_lines > 1

          index = result.next_index
          next
        end

        if char == "f" && heredoc_start?(line, index, format: true)
          raise LexError.new("format heredoc literals are not supported", line: line_number, column: index + 1, path: @path)
        end

        if char == "f" && line[index + 1] == '"'
          index = lex_format_string(line, index, line_number, line_offset:)
          next
        end

        if char == "<" && heredoc_start?(line, index)
          return lex_heredoc(lines, line_index, index, line_number, line_offset, cstring: false)
        end

        if char == '"'
          result = lex_string(lines, line_index, line, index, line_number, line_offset:)
          return result.consumed_lines if result.consumed_lines > 1

          index = result.next_index
          next
        end

        if identifier_start?(char)
          index = lex_identifier(line, index, line_number, line_offset:)
          next
        end

        if digit?(char)
          index = lex_number(line, index, line_number, line_offset:)
          next
        end

        index = lex_symbol(line, index, line_number, line_offset:)
      end

      newline_start = line_offset + line.length
      newline_end = has_newline ? (newline_start + 1) : newline_start
      if @grouping_depth.zero?
        if LINE_CONTINUATION_OPERATORS.include?(@tokens.last&.type)
          @continuation_pending = true
        else
          @tokens << token(:newline, "\n", nil, line_number, line.length + 1, start_offset: newline_start, end_offset: newline_end)
        end
      elsif with_trivia? && has_newline
        append_trailing_or_pending(
          TriviaToken.new(
            kind: :newline,
            text: "\n",
            line: line_number,
            column: line.length + 1,
            start_offset: newline_start,
            end_offset: newline_end,
          ),
        )
      end

      1
    end

    def register_detached_line_trivia(kind, line, line_number, line_offset, has_newline:)
      return unless with_trivia?

      text = has_newline ? (line + "\n") : line
      trivia = TriviaToken.new(
        kind:,
        text:,
        line: line_number,
        column: 1,
        start_offset: line_offset,
        end_offset: line_offset + text.bytesize,
      )
      @trivia << trivia
      push_pending_leading_trivia(trivia)
    end

    def push_pending_leading_trivia(trivia)
      return unless with_trivia?

      @trivia << trivia unless @trivia.include?(trivia)
      @pending_leading_trivia << trivia
    end

    def append_trailing_or_pending(trivia)
      return unless with_trivia?

      @trivia << trivia
      if @tokens.empty?
        @pending_leading_trivia << trivia
      else
        trailing = @pending_leading_trivia
        @pending_leading_trivia = []
        token = @tokens[-1]
        trailing.each { |entry| token = token.with_appended_trailing_trivia(entry) }
        token = token.with_appended_trailing_trivia(trivia)
        @tokens[-1] = token
      end
    end

    def emit_indentation(indent, line_number, line_offset)
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
        @tokens << token(:indent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
        return
      end

      while @indent_stack.last > indent
        @indent_stack.pop
        @tokens << token(:dedent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
      end

      return if @indent_stack.last == indent

      raise LexError.new("indentation does not match any open block", line: line_number, column: 1, path: @path)
    end

    def lex_identifier(line, index, line_number, line_offset:)
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

      @tokens << token(type, lexeme, literal, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index)
      index
    end

    def lex_number(line, index, line_number, line_offset:)
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

        if exponent_part?(line, index)
          type = :float
          index += 1
          index += 1 if %w[+ -].include?(line[index])
          while index < line.length && numeric_part?(line[index])
            index += 1
          end
        end
      end

      lexeme = line[start...index]
      if line[index, 5] == "float" && !identifier_part?(line[index + 5].to_s)
        type = :float
        index += 5
      elsif line[index, 6] == "double" && !identifier_part?(line[index + 6].to_s)
        type = :float
        index += 6
      end

      lexeme = line[start...index]
      literal = type == :integer ? parse_integer(lexeme) : lexeme.delete("_").delete_suffix("float").delete_suffix("double").to_f
      @tokens << token(type, lexeme, literal, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index)
      index
    end

    def lex_string(lines, line_index, line, index, line_number, line_offset:, cstring: false)
      segment = scan_string_segment(line, index, line_number, cstring:)
      consumed_lines = 1
      value = +segment.value
      last_line = line
      last_line_number = line_number
      last_line_offset = line_offset
      last_segment_end = segment.next_index
      last_line_has_newline = lines.fetch(line_index).end_with?("\n")
      remainder = line[segment.next_index..] || ""
      line_indent = leading_space_count(line)

      if remainder.strip.empty?
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

          continued_segment = scan_string_segment(scan_line, segment_start, scan_line_number, cstring:)
          continued_remainder = scan_line[continued_segment.next_index..] || ""
          break unless continued_remainder.strip.empty?

          value << continued_segment.value
          consumed_lines += 1
          last_line = scan_line
          last_line_number = scan_line_number
          last_line_offset = scan_line_offset
          last_segment_end = continued_segment.next_index
          last_line_has_newline = raw_line.end_with?("\n")

          scan_line_offset += raw_line.bytesize
          scan_line_number += 1
          scan_line_index += 1
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

    def scan_string_segment(line, index, line_number, cstring: false)
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

    def lex_heredoc(lines, line_index, index, line_number, line_offset, cstring:)
      line = lines.fetch(line_index).delete_suffix("\n").b
      prefix_length = heredoc_prefix(cstring:).length
      tag_start = index + prefix_length
      tag_end = tag_start
      tag_end += 1 while tag_end < line.length && identifier_part?(line[tag_end])
      tag = line[tag_start...tag_end]
      remainder = line[tag_end..] || ""

      unless heredoc_context_allowed?
        return lex_symbol(line, index, line_number, line_offset:)
      end

      unless remainder.strip.empty?
        raise LexError.new("unexpected characters after heredoc tag", line: line_number, column: tag_end + 1, path: @path)
      end

      content_lines = []
      terminator_line = nil
      terminator_line_number = nil
      terminator_line_offset = nil
      terminator_has_newline = false
      scan_line_number = line_number + 1
      scan_line_offset = line_offset + lines.fetch(line_index).bytesize
      scan_line_index = line_index + 1

      while scan_line_index < lines.length
        raw_line = lines.fetch(scan_line_index)
        raw_text = raw_line.delete_suffix("\n")
        if heredoc_terminator?(raw_text, tag)
          terminator_line = raw_text
          terminator_line_number = scan_line_number
          terminator_line_offset = scan_line_offset
          terminator_has_newline = raw_line.end_with?("\n")
          break
        end

        content_lines << raw_line
        scan_line_offset += raw_line.bytesize
        scan_line_number += 1
        scan_line_index += 1
      end

      raise LexError.new("unterminated heredoc literal", line: line_number, column: index + 1, path: @path) if terminator_line.nil?

      start_offset = line_offset + index
      end_offset = terminator_line_offset + terminator_line.bytesize
      lexeme = @source.byteslice(start_offset, end_offset - start_offset)
      value = dedent_heredoc_content(content_lines)

      @tokens << token(cstring ? :cstring : :string, lexeme, value, line_number, index + 1, start_offset:, end_offset:)
      emit_line_newline(terminator_line, terminator_line_number, terminator_line_offset, terminator_has_newline)

      (scan_line_index - line_index) + 1
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
          expr_end = scan_format_interpolation_end(line, expr_start, line_number, start + 1)
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

      raise LexError.new("unterminated format string literal", line: line_number, column: start + 1, path: @path)
    end

    def heredoc_start?(line, index, cstring: false, format: false)
      prefix = heredoc_prefix(cstring:, format:)
      line[index, prefix.length] == prefix && identifier_start?(line[index + prefix.length])
    end

    def heredoc_prefix(cstring: false, format: false)
      operator = "<<-"
      if cstring
        "c#{operator}"
      elsif format
        "f#{operator}"
      else
        operator
      end
    end

    def heredoc_context_allowed?
      allowed = %i[
        newline indent dedent
        equal plus_equal minus_equal star_equal slash_equal percent_equal
        amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
        lparen lbracket comma colon
        return defer if elif while match in
        or and not out inout
        plus minus star slash percent amp pipe caret shift_left shift_right
        less less_equal greater greater_equal equal_equal bang_equal
      ]
      previous_type = @tokens.last&.type
      previous_type.nil? || allowed.include?(previous_type)
    end

    def heredoc_terminator?(line, tag)
      line.match?(Regexp.new("\\A *#{Regexp.escape(tag)} *\\z"))
    end

    def dedent_heredoc_content(raw_lines)
      dedent_heredoc_lines(raw_lines).each_with_index.map do |text, index|
        text + (raw_lines[index].end_with?("\n") ? "\n" : "")
      end.join
    end

    def dedent_heredoc_lines(raw_lines)
      margin = raw_lines
               .map { |raw_line| raw_line.delete_suffix("\n") }
               .reject { |text| text.strip.empty? }
               .map { |text| leading_space_count(text) }
               .min || 0

      raw_lines.map do |raw_line|
        text = raw_line.delete_suffix("\n")
        text = text.strip.empty? ? "" : text[margin..]
        text || ""
      end
    end

    def emit_line_newline(line, line_number, line_offset, has_newline)
      newline_start = line_offset + line.bytesize
      newline_end = has_newline ? (newline_start + 1) : newline_start

      if @grouping_depth.zero?
        @tokens << token(:newline, "\n", nil, line_number, line.bytesize + 1, start_offset: newline_start, end_offset: newline_end)
      elsif with_trivia? && has_newline
        append_trailing_or_pending(
          TriviaToken.new(
            kind: :newline,
            text: "\n",
            line: line_number,
            column: line.bytesize + 1,
            start_offset: newline_start,
            end_offset: newline_end,
          ),
        )
      end
    end

    def scan_format_interpolation_end(line, index, line_number, column)
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

    # Splits a format interpolation source string into [expression_source, format_spec_string].
    # A colon at paren/bracket depth 0 separates the expression from the format spec.
    # Returns [source, nil] when no spec is present.
    def split_format_interpolation_source(source)
      depth = 0
      source.each_char.with_index do |char, i|
        case char
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1
        when ":"
          return [source[0...i], source[(i + 1)..]] if depth == 0
        end
      end
      [source, nil]
    end

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
        raise LexError.new("unexpected character #{lexeme.inspect}", line: line_number, column: start + 1, path: @path)
      end

      @tokens << token(type, lexeme, nil, line_number, start + 1, start_offset: line_offset + start, end_offset: line_offset + index + 1)
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

    def exponent_part?(line, index)
      return false unless %w[e E].include?(line[index])

      exponent_index = index + 1
      exponent_index += 1 if %w[+ -].include?(line[exponent_index])
      digit?(line[exponent_index])
    end

    def token(type, lexeme, literal, line, column, start_offset:, end_offset:)
      Token.new(
        type:,
        lexeme:,
        literal:,
        line:,
        column:,
        start_offset:,
        end_offset:,
        leading_trivia: consume_pending_leading_trivia,
        trailing_trivia: [],
      )
    end

    def consume_pending_leading_trivia
      return [] unless with_trivia?

      trivia = @pending_leading_trivia
      @pending_leading_trivia = []
      trivia
    end
  end
end
