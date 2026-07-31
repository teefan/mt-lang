# frozen_string_literal: true

module MilkTea
  TriviaToken = Data.define(:kind, :text, :line, :column, :start_offset, :end_offset)

  class Token < Data.define(:type, :lexeme, :literal, :line, :column, :start_offset, :end_offset, :leading_trivia, :trailing_trivia)
    KEYWORDS = MilkTea::KEYWORDS

    ASSIGNMENT_TYPES = %i[
      equal plus_equal minus_equal star_equal slash_equal percent_equal
      amp_equal pipe_equal caret_equal shift_left_equal shift_right_equal
    ].freeze

    # Operator token types that may never begin a statement. A statement
    # that spans multiple lines must end the previous line with one of
    # LINE_CONTINUATION_OPERATORS or wrap the expression in ( ) — it must
    # never start the next line with an operator.
    LINE_START_OPERATOR_TYPES = %i[
      dot_dot plus minus star slash percent
      pipe amp caret tilde
      or and is
      equal_equal bang_equal
      less less_equal greater greater_equal
      shift_left shift_right
    ].freeze

    # Binary operators that continue a statement when they end a physical
    # line. Unary-only `~` is excluded because it has no left operand.
    LINE_CONTINUATION_OPERATORS = (LINE_START_OPERATOR_TYPES - [:tilde]).freeze

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
