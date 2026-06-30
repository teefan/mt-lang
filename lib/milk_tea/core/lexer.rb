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
    StringSegment = Data.define(:next_index, :value, :recovered) do
      def initialize(next_index:, value:, recovered: false)
        super(next_index:, value:, recovered:)
      end
    end

    TOP_LEVEL_RESYNC_PREFIXES = %w[
      attribute const enum external flags foreign function include import interface
      link opaque public static_assert struct type union var variant extending event
    ].freeze

    LINE_CONTINUATION_OPERATORS = %i[
      dot_dot
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
      "@" => :at,
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

    INTEGER_SUFFIX_STRINGS = %w[ub us ul iz b s i u l z].sort_by { |s| -s.length }.freeze

    def self.lex(source, path: nil, mode: :syntax_only, recovery_errors: nil)
      result = new(source, path: path, mode:, recovery_errors:).lex
      mode == :with_trivia ? result.tokens : result
    end

    def self.lex_with_trivia(source, path: nil)
      new(source, path: path, mode: :with_trivia).lex
    end

    def initialize(source, path: nil, mode: :syntax_only, recovery_errors: nil)
      @source = source.gsub(/\r\n?/, "\n")
      @path = path
      @mode = mode
      @recovery_errors = recovery_errors
      @tokens = []
      @trivia = []
      @pending_leading_trivia = []
      @indent_stack = [0]
      @grouping_depth = 0
      @grouping_start_line = 0
      @grouping_start_column = 0
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
        line = raw_line.delete_suffix("\n").b
        consumed_lines = lex_line(lines, line_index, line, line_number, line_offset, has_newline:)

        consumed_lines.times do |delta|
          line_offset += lines.fetch(line_index + delta).bytesize
        end
        line_number += consumed_lines
        line_index += consumed_lines
      end

      if @grouping_depth.positive?
        if @recovery_errors
          @recovery_errors << LexError.new("unclosed grouping delimiter", line: @grouping_start_line, column: @grouping_start_column, path: @path)
          @grouping_depth = 0
        else
          raise LexError.new("unclosed grouping delimiter", line: @line_count, column: 1, path: @path)
        end
      end

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
        error = LexError.new("tabs are not allowed; use 4 spaces for indentation", line: line_number, column: tab_index + 1, path: @path)
        if @recovery_errors
          @recovery_errors << error
          line = line.gsub("\t", "    ")
        else
          raise error
        end
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
      if @recovery_errors && @grouping_depth.positive? && index.zero? && top_level_resync_line?(line)
        @recovery_errors << LexError.new("unclosed grouping delimiter", line: @grouping_start_line, column: @grouping_start_column, path: @path)
        @grouping_depth = 0
        @tokens << token(:newline, "\n", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
      end

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
        if @continuation_pending
        elsif @recovery_errors
          begin
            emit_indentation(index, line_number, line_offset)
          rescue LexError => e
            @recovery_errors << e
            recover_indentation(index, line_number, line_offset)
          end
        else
          emit_indentation(index, line_number, line_offset)
        end
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

        if char == "c" && line[index + 1] == "<" && line[index + 2] == "-" && identifier_start?(line[index + 3])
          error = LexError.new("expected '<<-' for heredoc string; did you mean 'c<<-#{identifier_start_token(line, index + 3)}'?", line: line_number, column: index + 1, path: @path)
          if @recovery_errors
            @recovery_errors << error
          else
            raise error
          end
        end
        if char == "c" && line[index + 1] == '"'
          result = lex_string(lines, line_index, line, index, line_number, line_offset:, cstring: true)
          return result.consumed_lines if result.consumed_lines > 1

          index = result.next_index
          next
        end

        if char == "f" && heredoc_start?(line, index, format: true)
          return lex_heredoc(lines, line_index, index, line_number, line_offset, cstring: false, format: true)
        end

        if char == "f" && line[index + 1] == "<" && line[index + 2] == "-" && identifier_start?(line[index + 3])
          error = LexError.new("expected '<<-' for heredoc string; did you mean 'f<<-#{identifier_start_token(line, index + 3)}'?", line: line_number, column: index + 1, path: @path)
          if @recovery_errors
            @recovery_errors << error
          else
            raise error
          end
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

        if char == "'"
          index = lex_char_literal(line, index, line_number, line_offset:)
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

    # ── trivia helpers ──────────────────────────────────────────────

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
      push_pending_leading_trivia(trivia)
    end

    def push_pending_leading_trivia(trivia)
      return unless with_trivia?

      @trivia << trivia
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

    # ── indentation ─────────────────────────────────────────────────

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

    def recover_indentation(indent, line_number, line_offset)
      recovered_indent = indent - (indent % 4)
      current_indent = @indent_stack.last

      if recovered_indent > current_indent + 4
        recovered_indent = current_indent + 4
      end

      if recovered_indent > current_indent
        @indent_stack << recovered_indent
        @tokens << token(:indent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
        return
      end

      while @indent_stack.last > recovered_indent
        @indent_stack.pop
        @tokens << token(:dedent, "", nil, line_number, 1, start_offset: line_offset, end_offset: line_offset)
      end

      return if @indent_stack.last == recovered_indent
    end

    # ── identifier lexing ───────────────────────────────────────────

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

    # ── numeric lexing ──────────────────────────────────────────────

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

    # ── text-literal lexing (string / char / heredoc / format) ──────

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

    def lex_heredoc(lines, line_index, index, line_number, line_offset, cstring:, format: false)
      line = lines.fetch(line_index).delete_suffix("\n").b
      prefix_length = heredoc_prefix(cstring:, format:).length
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
      last_line = line
      last_line_number = line_number
      last_line_offset = line_offset
      last_line_has_newline = lines.fetch(line_index).end_with?("\n")
      resync_line_offset = nil
      resync_line_number = nil
      scan_line_number = line_number + 1
      scan_line_offset = line_offset + lines.fetch(line_index).bytesize
      scan_line_index = line_index + 1

      content_min_indent = nil

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

        if @recovery_errors && content_min_indent&.positive? && top_level_resync_line?(raw_text)
          resync_line_offset = scan_line_offset
          resync_line_number = scan_line_number
          break
        end

        content_lines << raw_line
        last_line = raw_text
        last_line_number = scan_line_number
        last_line_offset = scan_line_offset
        last_line_has_newline = raw_line.end_with?("\n")
        scan_line_offset += raw_line.bytesize
        scan_line_number += 1
        scan_line_index += 1

        unless raw_text.strip.empty?
          line_indent = leading_space_count(raw_text)
          content_min_indent = line_indent if content_min_indent.nil? || line_indent < content_min_indent
        end
      end

      if terminator_line.nil? && @recovery_errors && resync_line_number.nil? && scan_line_index < lines.length
        trailing_text = lines.fetch(scan_line_index).delete_suffix("\n")
        if top_level_resync_line?(trailing_text)
          resync_line_offset = scan_line_offset
          resync_line_number = scan_line_number
        end
      end

      if terminator_line.nil?
        if @recovery_errors
          @recovery_errors << LexError.new("unterminated heredoc literal", line: line_number, column: index + 1, path: @path)
          start_offset = line_offset + index
          end_offset = resync_line_offset || scan_line_offset
          lexeme = @source.byteslice(start_offset, end_offset - start_offset)
          value = dedent_heredoc_content(content_lines)
          content_margin = heredoc_content_margin(content_lines)

          literal = if format
                       parse_format_heredoc_parts(value, start_line: line_number + 1, start_column: content_margin + 1)
                     else
                       value
                     end
          token_type = if format
                         :fstring
                       elsif cstring
                         :cstring
                       else
                         :string
                       end

          @tokens << token(token_type, lexeme, literal, line_number, index + 1, start_offset:, end_offset:)
          emit_line_newline(last_line, last_line_number, last_line_offset, last_line_has_newline)
          return resync_line_number ? (resync_line_number - line_number) : (scan_line_index - line_index)
        end

        raise LexError.new("unterminated heredoc literal", line: line_number, column: index + 1, path: @path)
      end

      start_offset = line_offset + index
      end_offset = terminator_line_offset + terminator_line.bytesize
      lexeme = @source.byteslice(start_offset, end_offset - start_offset)
      value = dedent_heredoc_content(content_lines)
      content_margin = heredoc_content_margin(content_lines)

      literal = if format
                   parse_format_heredoc_parts(value, start_line: line_number + 1, start_column: content_margin + 1)
                 else
                   value
                 end
      token_type = if format
                     :fstring
                   elsif cstring
                     :cstring
                   else
                     :string
                   end

      @tokens << token(token_type, lexeme, literal, line_number, index + 1, start_offset:, end_offset:)
      emit_line_newline(terminator_line, terminator_line_number, terminator_line_offset, terminator_has_newline)

      (scan_line_index - line_index) + 1
    end

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

    def advance_text_position(char:, line:, column:)
      if char == "\n"
        [line + 1, 1]
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

    # ── heredoc helpers ─────────────────────────────────────────────

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
        return defer if else while match in
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

    def heredoc_content_margin(raw_lines)
      raw_lines
        .map { |raw_line| raw_line.delete_suffix("\n") }
        .reject { |text| text.strip.empty? }
        .map { |text| leading_space_count(text) }
        .min || 0
    end

    def dedent_heredoc_content(raw_lines)
      dedent_heredoc_lines(raw_lines).each_with_index.map do |text, index|
        text + (raw_lines[index].end_with?("\n") ? "\n" : "")
      end.join
    end

    def dedent_heredoc_lines(raw_lines)
      margin = heredoc_content_margin(raw_lines)

      raw_lines.map do |raw_line|
        text = raw_line.delete_suffix("\n")
        text = text.strip.empty? ? "" : text[margin..]
        text || ""
      end
    end

    # ── format interpolation helpers ────────────────────────────────

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

    # ── newline emission ────────────────────────────────────────────

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

    # ── symbol / operator lexing ────────────────────────────────────

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

    # ── recovery ────────────────────────────────────────────────────

    def top_level_resync_line?(line)
      return false if line.strip.empty?
      return false if leading_space_count(line).positive?

      first_word = line.strip.split(/\s+/, 3)[0]
      second_word = line.strip.split(/\s+/, 3)[1]

      case first_word
      when *TOP_LEVEL_RESYNC_PREFIXES
        true
      when "async"
        second_word == "function"
      when "public"
        %w[function struct union enum flags variant type const var opaque interface extending attribute event].include?(second_word)
      when "foreign", "external"
        second_word == "function"
      else
        false
      end
    end

    # ── integer / escape utilities ──────────────────────────────────

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
      when "0" then "\0"
      when '"' then '"'
      when "'" then "'"
      when "\\" then "\\"
      else char
      end
    end

    # ── character classification ────────────────────────────────────

    def leading_space_count(line)
      line[/\A */].length
    end

    def identifier_start?(char)
      char.match?(/[A-Za-z_]/)
    end

    def identifier_part?(char)
      char.match?(/[A-Za-z0-9_]/)
    end

    def identifier_start_token(line, start_index)
      return "" unless start_index < line.length && identifier_start?(line[start_index])

      finish = start_index + 1
      finish += 1 while finish < line.length && identifier_part?(line[finish])
      line[start_index...finish]
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

    # ── token construction ──────────────────────────────────────────

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
