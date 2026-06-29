# frozen_string_literal: true

require_relative "helpers"

class NullableCodegenTest < Minitest::Test
  include CodegenTestHelpers

  # --- local variable nullable assignment (inline-tagged representation) ---

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
    assert_match(/result = \(mt_opt_\w+\)\{ \.has_value = true, \.value = /, generated,
                "nullable assignment must construct a tagged optional value")
    refute_match(/nullable_assign|nullable_loc/, generated,
                "tagged nullable must not use the pointer-to-temp machinery")
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
    assert_match(/x = \(mt_opt_int32_t\)\{ \.has_value = true, \.value = 42 \}/, generated,
                "nullable int assignment must construct a tagged optional")
    refute_match(/nullable_assign/, generated,
                "tagged nullable must not use a pointer-to-temp")
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
    assert_match(/result = \(mt_opt_demo_nullstruct_Point\)\{ \.has_value = true, \.value = demo_nullstruct_make_point\(3, 4\) \}/, generated,
                "nullable struct assignment must construct a tagged optional by value")
    refute_match(/nullable_assign/, generated,
                "tagged nullable must not use a pointer-to-temp")
  end

  # --- nullable struct/variant field construction (inline-tagged) ---

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
    assert_match(/\.body = \{ \.has_value = true, \.value = raw \}/, generated,
                "non-nullable local passed to nullable struct field must wrap as a tagged optional")
    refute_match(/\.body = &raw\b/, generated,
                "tagged nullable field must NOT take the address of a stack local")
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
                "already-nullable local should pass the tagged optional directly (by value)")
  end

  # --- let-else nullable unwrapping (tagged .value projection) ---

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
    assert_match(/process_block\(y\.value\)/, generated,
                "let-else nullable struct unwrap must read the tagged .value field")
    refute_match(/\*y\b/, generated,
                "tagged nullable unwrap must NOT dereference a pointer")
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
    assert_match(/process_int\(val_i\.value\)/, generated,
                "let-else nullable int unwrap must read the tagged .value field")
    refute_match(/process_int\(\*val_i\)/, generated,
                "tagged nullable unwrap must NOT dereference a pointer")
  end

  # --- nullable rvalue wrapping (tagged construction, no temp) ---

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
    assert_match(/\.port = \{ \.has_value = true, \.value = demo_rvalue_make_port\(\) \}/, generated,
                "nullable struct field with rvalue must construct a tagged optional inline")
    refute_match(/__mt_nullable_agg/, generated,
                "tagged nullable must not use a pointer-to-temp")
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
    assert_match(/\.val = \{ \.has_value = true, \.value = demo_rvalue2_make_val\(\) \}/, generated,
                "nullable field with rvalue in struct literal must construct a tagged optional inline")
    refute_match(/__mt_nullable_agg/, generated,
                "tagged nullable must not use a pointer-to-temp")
  end

  # --- regression: nullable value field returned by value must not dangle ---

  def test_nullable_value_field_returned_by_value_is_not_dangling
    source = <<~MT
      # module demo.nodangle

      struct Box:
          value: int?

      function make() -> Box:
          let local = 7
          return Box(value = local)

      function main() -> int:
          let b = make()
          let v = b.value
          if v != null:
              return v
          return 0
    MT

    generated = generate_c_from_program_source(source)
    assert_match(/struct demo_nodangle_Box \{\s+mt_opt_int32_t value;\s+\}/m, generated,
                "nullable value field must be stored inline as a tagged optional, not a pointer")
    assert_match(/\.value = \{ \.has_value = true, \.value = local \}/, generated,
                "constructing the field must copy the value into the tagged optional")
    refute_match(/&local\b/, generated,
                "must NOT take the address of a stack local that escapes the function")
    refute_match(/nullable_loc|nullable_agg/, generated,
                "tagged nullable construction must not allocate a pointer-to-temp")
  end
end
