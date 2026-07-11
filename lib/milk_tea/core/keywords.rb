# frozen_string_literal: true

module MilkTea
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

  BUILTIN_PRIMITIVE_NAMES = %w[
    bool byte ubyte char short ushort int uint long ulong ptr_int ptr_uint float double void str cstr
    vec2 vec3 vec4 ivec2 ivec3 ivec4 mat3 mat4 quat
  ].freeze

  RESERVED_VALUE_TYPE_NAMES = (BUILTIN_PRIMITIVE_NAMES + %w[
    Option Result
  ]).freeze

  RESERVED_IMPORT_ALIAS_NAMES = %w[
    Option Result
  ].freeze

  BUILTIN_TYPE_NAMES = (BUILTIN_PRIMITIVE_NAMES + %w[
    ptr const_ptr own ref span array str_buffer atomic Task Option Result SoA
    struct_handle field_handle callable_handle attribute_handle member_handle type
    EventError Subscription
  ]).freeze
end
