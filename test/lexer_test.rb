# frozen_string_literal: true

require_relative "test_helper"

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
end
