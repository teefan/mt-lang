# frozen_string_literal: true

module MilkTea
  class Token < Data.define(:type, :lexeme, :literal, :line, :column)
    KEYWORDS = {
      "and" => :and,
      "as" => :as,
      "const" => :const,
      "def" => :def,
      "defer" => :defer,
      "enum" => :enum,
      "elif" => :elif,
      "else" => :else,
      "extern" => :extern,
      "false" => :false,
      "flags" => :flags,
      "fn" => :fn,
      "if" => :if,
      "impl" => :impl,
      "include" => :include,
      "import" => :import,
      "let" => :let,
      "link" => :link,
      "module" => :module,
      "mut" => :mut,
      "not" => :not,
      "null" => :null,
      "opaque" => :opaque,
      "or" => :or,
      "return" => :return,
      "struct" => :struct,
      "type" => :type,
      "true" => :true,
      "union" => :union,
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
