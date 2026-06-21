# frozen_string_literal: true

module MilkTea
  TriviaToken = Data.define(:kind, :text, :line, :column, :start_offset, :end_offset)

  class Token < Data.define(:type, :lexeme, :literal, :line, :column, :start_offset, :end_offset, :leading_trivia, :trailing_trivia)
    KEYWORDS = MilkTea::KEYWORDS

    ASSIGNMENT_TYPES = %i[
      equal plus_equal minus_equal star_equal slash_equal percent_equal
      amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
    ].freeze

    def assignment?
      ASSIGNMENT_TYPES.include?(type)
    end

    def eof?
      type == :eof
    end

    def with_appended_trailing_trivia(trivia)
      with(trailing_trivia: trailing_trivia + [trivia])
    end
  end
end
