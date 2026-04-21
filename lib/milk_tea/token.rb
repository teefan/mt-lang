# frozen_string_literal: true

module MilkTea
  class Token < Data.define(:type, :lexeme, :literal, :line, :column)
    KEYWORDS = {
      "and" => :and,
      "as" => :as,
      "const" => :const,
      "def" => :def,
      "defer" => :defer,
      "elif" => :elif,
      "else" => :else,
      "false" => :false,
      "if" => :if,
      "impl" => :impl,
      "import" => :import,
      "let" => :let,
      "module" => :module,
      "mut" => :mut,
      "not" => :not,
      "null" => :null,
      "or" => :or,
      "return" => :return,
      "struct" => :struct,
      "true" => :true,
      "var" => :var,
      "while" => :while,
    }.freeze

    ASSIGNMENT_TYPES = %i[equal plus_equal minus_equal star_equal slash_equal].freeze

    def assignment?
      ASSIGNMENT_TYPES.include?(type)
    end

    def eof?
      type == :eof
    end
  end
end
