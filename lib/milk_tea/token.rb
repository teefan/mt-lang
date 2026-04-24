# frozen_string_literal: true

module MilkTea
  class Token < Data.define(:type, :lexeme, :literal, :line, :column)
    KEYWORDS = {
      "align" => :align,
      "and" => :and,
      "alignof" => :alignof,
      "as" => :as,
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
      "if" => :if,
      "include" => :include,
      "in" => :in,
      "import" => :import,
      "let" => :let,
      "link" => :link,
      "match" => :match,
      "methods" => :methods,
      "module" => :module,
      "mut" => :mut,
      "not" => :not,
      "null" => :null,
      "offsetof" => :offsetof,
      "opaque" => :opaque,
      "or" => :or,
      "packed" => :packed,
      "pub" => :pub,
      "return" => :return,
      "sizeof" => :sizeof,
      "static" => :static,
      "static_assert" => :static_assert,
      "struct" => :struct,
      "type" => :type,
      "unsafe" => :unsafe,
      "true" => :true,
      "then" => :then,
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
