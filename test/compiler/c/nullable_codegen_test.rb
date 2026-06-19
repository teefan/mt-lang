# frozen_string_literal: true

require_relative "helpers"

class NullableCodegenTest < Minitest::Test
  include CodegenTestHelpers

  # --- existing: local variable nullable assignment (block.rb fix) ---

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

  # --- new: variant constructor nullable field (expressions.rb fix) ---

  def test_non_nullable_local_to_nullable_variant_field
    source = <<~MT
      # module demo.nullvariant

      struct Decl:
          value: int?
          body: int?

      function wrap_value(raw: int) -> Decl:
          return Decl(value = raw, body = raw)

      function main() -> int:
          let decl = wrap_value(42)
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/\.body = &raw\b/, generated,
                "non-nullable local passed to nullable variant field must use address-of")
  end

  def test_already_nullable_local_to_nullable_variant_field
    source = <<~MT
      # module demo.nullboth

      struct Expr:
          inner: int?

      function get_inner() -> int:
          return 10

      function build_expr() -> Expr:
          var opt: int? = null
          opt = get_inner()
          return Expr(inner = opt)

      function main() -> int:
          let e = build_expr()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/\.inner = opt\b/, generated,
                "already-nullable local should pass directly (no extra &)")
  end
end
