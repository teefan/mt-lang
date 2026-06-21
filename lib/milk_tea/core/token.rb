# frozen_string_literal: true

module MilkTea
  TriviaToken = Data.define(:kind, :text, :line, :column, :start_offset, :end_offset)

  class Token < Data.define(:type, :lexeme, :literal, :line, :column, :start_offset, :end_offset, :leading_trivia, :trailing_trivia)
    KEYWORDS = {
      "align_of" => :align_of,
      "and" => :and,
      "as" => :as,
      "async" => :async,
      "attribute" => :attribute,
      "attribute_arg" => :attribute_arg,
      "attribute_of" => :attribute_of,
      "attributes_of" => :attributes_of,
      "await" => :await,
      "break" => :break,
      "const" => :const,
      "compiler_flag" => :compiler_flag,
      "gather" => :gather,
      "continue" => :continue,
      "function" => :function,
      "has_attribute" => :has_attribute,
      "defer" => :defer,
      "detach" => :detach,
      "dyn" => :dyn,
      "editable" => :editable,
      "enum" => :enum,
      "else" => :else,
      "emit" => :emit,
      "event" => :event,
      "external" => :external,
      "false" => :false,
      "callable_of" => :callable_of,
      "fields_of" => :fields_of,
      "field_of" => :field_of,
      "flags" => :flags,
      "fn" => :fn,
      "for" => :for,
      "foreign" => :foreign,
      "if" => :if,
      "implements" => :implements,
      "include" => :include,
      "in" => :in,
      "inline" => :inline,
      "inout" => :inout,
      "import" => :import,
      "interface" => :interface,
      "is" => :is,
      "let" => :let,
      "link" => :link,
      "match" => :match,
      "members_of" => :members_of,
      "extending" => :extending,
      "module" => :module,
      "not" => :not,
      "null" => :null,
      "offset_of" => :offset_of,
      "opaque" => :opaque,
      "consuming" => :consuming,
      "or" => :or,
      "out" => :out,
      "parallel" => :parallel,
      "pass" => :pass,
      "proc" => :proc,
      "public" => :public,
      "return" => :return,
      "size_of" => :size_of,
      "static" => :static,
      "static_assert" => :static_assert,
      "struct" => :struct,
      "type" => :type,
      "unsafe" => :unsafe,
      "true" => :true,
      "union" => :union,
      "var" => :var,
      "variant" => :variant,
      "when" => :when,
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
