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
                "non-nullable local passed to nullable struct field must use address-of")
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

  # --- let-else nullable unwrapping (lower_bound_identifier deref fix) ---

  def test_let_else_nullable_struct_passed_to_function
    source = <<~MT
      # module demo.letelse

      struct Block:
          count: int

      function process_block(block: Block) -> int:
          return block.count

      function test() -> int:
          var x: Block? = Block(count = 42)
          let y = x else:
              return 0
          return process_block(y)

      function main() -> int:
          return test()
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/Block __mt_n/, generated, "let-else nullable struct must create value-typed temp")
    assert_match(/\*y/, generated, "let-else nullable struct reference must dereference *y")
  end

  def test_let_else_nullable_int_passed_to_function
    source = <<~MT
      # module demo.letint

      function process_int(val: int) -> int:
          return val * 2

      function test() -> int:
          var i: int? = 21
          let val_i = i else:
              return 0
          return process_int(val_i)

      function main() -> int:
          return test()
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/process_int\(\*val_i\)/, generated,
                "let-else nullable int reference must dereference *val_i in call")
    refute_match(/process_int\(val_i\);/, generated,
                "let-else nullable int reference must NOT pass pointer directly")
  end

  # --- nullable rvalue wrapping (Bug 10: wrap_nullable_field_value) ---

  def test_nullable_struct_field_with_rvalue_initializer
    source = <<~MT
      # module demo.rvalue

      struct Config:
          port: int?

      function make_port() -> int:
          return 8080

      function make_config() -> Config:
          return Config(port = make_port())

      function main() -> int:
          var c = make_config()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/__mt_nullable_agg/, generated,
                "nullable struct field with rvalue must use temp variable")
    refute_match(/&make_port\(\)/, generated,
                   "nullable struct field must NOT emit &func_call()")
  end

  def test_nullable_variant_field_with_rvalue_initializer
    source = <<~MT
      # module demo.rvalue2

      variant Opt:
          some(value: int)
          none

      struct Holder:
          val: int?

      function make_val() -> int:
          return 99

      function make_holder() -> Holder:
          return Holder(val = make_val())

      function main() -> int:
          var h = make_holder()
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/__mt_nullable_agg/, generated,
                "nullable field with rvalue in struct literal must use temp")
  end
end
