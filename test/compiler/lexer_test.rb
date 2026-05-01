# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaLexerTest < Minitest::Test
  def test_emits_indent_and_dedent_tokens_for_blocks
    source = <<~MT
      module demo.main

      struct Ball:
          radius: f32
    MT

    types = MilkTea::Lexer.lex(source).map(&:type)

    assert_equal(
      %i[module identifier dot identifier newline struct identifier colon newline indent identifier colon identifier newline dedent eof],
      types,
    )
  end

  def test_rejects_tabs
    source = <<~MT
      def main() -> i32:
	return 0
    MT

    error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex(source)
    end

    assert_match(/tabs are not allowed/, error.message)
  end

  def test_ignores_indentation_inside_parenthesized_calls
    source = <<~MT
      def main() -> i32:
          var ball = Ball(
              radius = 20.0,
          )
          return 0
    MT

    tokens = MilkTea::Lexer.lex(source)
    types = tokens.map(&:type)

    assert_equal 1, types.count(:indent)
    assert_equal 1, types.count(:dedent)
  end

  def test_lexes_cstrings_booleans_nulls_and_non_decimal_numbers
    source = <<~MT
      const mask: i32 = 0xff
      const bits: i32 = 0b1010
      const title: cstr = c"Milk\\nTea"
      const ready: bool = true
      const missing: ptr[Window]? = null
    MT

    tokens = MilkTea::Lexer.lex(source)

    assert_equal 0xff, tokens.find { |token| token.lexeme == "0xff" }.literal
    assert_equal 0b1010, tokens.find { |token| token.lexeme == "0b1010" }.literal
    assert_equal "Milk\nTea", tokens.find { |token| token.type == :cstring }.literal
    assert_equal true, tokens.find { |token| token.type == :true }.literal
    assert_nil tokens.find { |token| token.type == :null }.literal
  end

  def test_lexes_scientific_float_literals
    source = <<~MT
      const epsilon: f32 = 1.1920929E-7
      const large: f64 = 2e+3
    MT

    tokens = MilkTea::Lexer.lex(source)

    assert_in_delta 1.1920929e-7, tokens.find { |token| token.lexeme == "1.1920929E-7" }.literal, 1e-15
    assert_in_delta 2000.0, tokens.find { |token| token.lexeme == "2e+3" }.literal, 1e-12
  end

  def test_reports_indentation_and_grouping_errors
    indentation_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex("def main() -> i32:\n  return 0\n")
    end
    assert_match(/multiples of 4 spaces/, indentation_error.message)

    grouping_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex(")\n")
    end
    assert_match(/unexpected closing delimiter/, grouping_error.message)

    unclosed_grouping_error = assert_raises(MilkTea::LexError) do
      MilkTea::Lexer.lex("var ball = Ball(\n")
    end
    assert_match(/unclosed grouping delimiter/, unclosed_grouping_error.message)
  end

  def test_lexes_bitwise_tokens_and_normal_strings
    source = <<~MT
      const mask: u32 = ~0 | 1 & 2 ^ 4 << 1 >> 0
      link "c"
    MT

    types = MilkTea::Lexer.lex(source).map(&:type)

    assert_includes types, :tilde
    assert_includes types, :pipe
    assert_includes types, :amp
    assert_includes types, :caret
    assert_includes types, :shift_left
    assert_includes types, :shift_right
    assert_includes types, :string
  end

  def test_lexes_ellipsis_token
    types = MilkTea::Lexer.lex("extern def printf(format: cstr, ...) -> i32\n").map(&:type)

    assert_includes types, :ellipsis
  end

  def test_lexes_format_string_literal_parts
    tokens = MilkTea::Lexer.lex("const message = f\"value=\#{count} ok=\#{true}\"\n")
    format_token = tokens.find { |token| token.type == :fstring }

    refute_nil format_token
    assert_equal [:text, :expr, :text, :expr], format_token.literal.map { |part| part.fetch(:kind) }
    assert_equal "value=", format_token.literal[0].fetch(:value)
    assert_equal "count", format_token.literal[1].fetch(:source)
    assert_equal " ok=", format_token.literal[2].fetch(:value)
    assert_equal "true", format_token.literal[3].fetch(:source)
  end

  def test_lex_with_trivia_captures_comments_and_blank_lines
    source = <<~MT
      # module banner

      def main() -> i32: # inline doc
          return 0
    MT

    result = MilkTea::Lexer.lex_with_trivia(source)

    comment_kinds = result.trivia.select { |token| token.kind == :comment }
    blank_line_kinds = result.trivia.select { |token| token.kind == :blank_line }

    assert_equal 2, comment_kinds.length
    assert_equal 1, blank_line_kinds.length

    main_token = result.tokens.find { |token| token.lexeme == "def" }
    refute_nil main_token
    assert_equal true, main_token.leading_trivia.any? { |token| token.kind == :comment }

    colon_token = result.tokens.find { |token| token.type == :colon }
    refute_nil colon_token
    assert_equal true, colon_token.trailing_trivia.any? { |token| token.kind == :comment }
  end

  def test_lexed_tokens_include_source_offsets
    tokens = MilkTea::Lexer.lex("let answer = 42\n")
    let_token = tokens.find { |token| token.lexeme == "let" }
    int_token = tokens.find { |token| token.lexeme == "42" }

    refute_nil let_token
    refute_nil int_token
    assert_equal 0, let_token.start_offset
    assert_equal 3, let_token.end_offset
    assert_equal 13, int_token.start_offset
    assert_equal 15, int_token.end_offset
  end
end
