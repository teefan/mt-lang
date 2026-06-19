# frozen_string_literal: true

require_relative "helpers"

class NullableCodegenTest < Minitest::Test
  include CodegenTestHelpers

  def test_assign_string_to_nullable_variable
    source = <<~MT
      # module demo.nullable

      import std.string as string

      function get_name(kind: int) -> string.String?:
          var result: string.String? = null
          result = string.String.from_str("hello")
          return result

      function main() -> int:
          let name = get_name(1)
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/nullable_assign/, generated,
                "nullable assignment must use temp variable + address-of")
  end

  def test_assign_integer_to_nullable_variable
    source = <<~MT
      # module demo.nullint

      function get_value() -> int?:
          var x: int? = null
          x = 42
          return x

      function main() -> int:
          let v = get_value()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/nullable_assign/, generated,
                "nullable int assignment must use temp variable")
  end

  def test_assign_struct_to_nullable_variable
    source = <<~MT
      # module demo.nullstruct

      struct Point:
          x: int
          y: int

      function make_point(x: int, y: int) -> Point:
          return Point(x = x, y = y)

      function get_point() -> Point?:
          var result: Point? = null
          result = make_point(3, 4)
          return result

      function main() -> int:
          let pt = get_point()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/nullable_assign/, generated,
                "nullable struct assignment must use temp variable")
  end
end
