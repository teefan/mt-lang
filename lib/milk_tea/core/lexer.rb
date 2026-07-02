# frozen_string_literal: true

require_relative "lexer/character_classes"
require_relative "lexer/trivia"
require_relative "lexer/indentation"
require_relative "lexer/numbers"
require_relative "lexer/strings"
require_relative "lexer/heredocs"
require_relative "lexer/format_strings"
require_relative "lexer/symbols"
require_relative "lexer/recovery"

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

    # Byte-classification lookup tables (indexed 0..255). Scanning by raw byte
    # via String#getbyte avoids allocating a one-character String and running
    # the regex engine for every source character, which dominated lexing.
    IDENT_START_BYTE = Array.new(256) { |b| b.chr.match?(/[A-Za-z_]/) }.freeze
    IDENT_PART_BYTE = Array.new(256) { |b| b.chr.match?(/[A-Za-z0-9_]/) }.freeze
    DIGIT_BYTE = Array.new(256) { |b| b.chr.match?(/[0-9]/) }.freeze
    NUMERIC_PART_BYTE = Array.new(256) { |b| b.chr.match?(/[0-9_]/) }.freeze
    HEX_DIGIT_BYTE = Array.new(256) { |b| b.chr.match?(/[0-9a-fA-F_]/) }.freeze
    BIN_DIGIT_BYTE = Array.new(256) { |b| b.chr.match?(/[01_]/) }.freeze
    SPACE_BYTE = " ".ord

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

    include CharacterClasses
    include Trivia
    include Indentation
    include Numbers
    include Strings
    include Heredocs
    include FormatStrings
    include Symbols
    include Recovery

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
