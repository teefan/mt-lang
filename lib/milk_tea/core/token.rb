# frozen_string_literal: true

module MilkTea
  TriviaToken = Data.define(:kind, :text, :line, :column, :start_offset, :end_offset)

  class Token < Data.define(:type, :lexeme, :literal, :line, :column, :start_offset, :end_offset, :leading_trivia, :trailing_trivia)
    KEYWORDS = {
      "align" => :align,
      "and" => :and,
      "alignof" => :alignof,
      "as" => :as,
      "async" => :async,
      "await" => :await,
      "break" => :break,
      "const" => :const,
      "continue" => :continue,
      "def" => :def,
      "defer" => :defer,
      "edit" => :edit,
      "enum" => :enum,
      "elif" => :elif,
      "else" => :else,
      "extern" => :extern,
      "false" => :false,
      "flags" => :flags,
      "fn" => :fn,
      "for" => :for,
      "foreign" => :foreign,
      "if" => :if,
      "include" => :include,
      "in" => :in,
      "inout" => :inout,
      "import" => :import,
      "let" => :let,
      "link" => :link,
      "match" => :match,
      "methods" => :methods,
      "module" => :module,
      "not" => :not,
      "null" => :null,
      "offsetof" => :offsetof,
      "opaque" => :opaque,
      "consuming" => :consuming,
      "or" => :or,
      "out" => :out,
      "packed" => :packed,
      "proc" => :proc,
      "pub" => :pub,
      "return" => :return,
      "sizeof" => :sizeof,
      "static" => :static,
      "static_assert" => :static_assert,
      "struct" => :struct,
      "type" => :type,
      "unsafe" => :unsafe,
      "true" => :true,
      "union" => :union,
      "var" => :var,
      "variant" => :variant,
      "while" => :while,
    }.freeze

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
