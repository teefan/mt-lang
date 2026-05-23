# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaTokenStreamTest < Minitest::Test
  def test_syntax_token_stream_wraps_tokens_with_index_and_length
    tokens = [
      MilkTea::Token.new(type: :identifier, lexeme: "x", literal: nil, line: 1, column: 1, start_offset: 0, end_offset: 1, leading_trivia: [], trailing_trivia: []),
      MilkTea::Token.new(type: :eof, lexeme: "", literal: nil, line: 1, column: 2, start_offset: 1, end_offset: 1, leading_trivia: [], trailing_trivia: []),
    ]

    stream = MilkTea::SyntaxTokenStream.new(tokens)

    assert_equal 2, stream.length
    assert_equal :identifier, stream[0].type
    assert_equal :eof, stream[1].type
    assert_same tokens, stream.to_a
  end

  def test_trivia_token_stream_exposes_tokens_and_trivia
    tokens = [MilkTea::Token.new(type: :identifier, lexeme: "value", literal: nil, line: 1, column: 1, start_offset: 0, end_offset: 5, leading_trivia: [], trailing_trivia: [])]
    trivia = [MilkTea::TriviaToken.new(kind: :comment, text: "# note", line: 1, column: 7, start_offset: 6, end_offset: 12)]

    stream = MilkTea::TriviaTokenStream.new(tokens, trivia)

    assert_same tokens, stream.tokens
    assert_same trivia, stream.trivia
  end

  def test_token_helpers_detect_assignment_and_eof_and_append_trivia
    token = MilkTea::Token.new(type: :plus_equal, lexeme: "+=", literal: nil, line: 2, column: 3, start_offset: 10, end_offset: 12, leading_trivia: [], trailing_trivia: [])
    eof = MilkTea::Token.new(type: :eof, lexeme: "", literal: nil, line: 3, column: 1, start_offset: 20, end_offset: 20, leading_trivia: [], trailing_trivia: [])
    comment = MilkTea::TriviaToken.new(kind: :comment, text: "# trailing", line: 2, column: 6, start_offset: 13, end_offset: 23)

    assert token.assignment?
    refute token.eof?
    refute eof.assignment?
    assert eof.eof?

    updated = token.with_appended_trailing_trivia(comment)
    assert_equal 1, updated.trailing_trivia.length
    assert_equal "# trailing", updated.trailing_trivia.first.text
  end
end
