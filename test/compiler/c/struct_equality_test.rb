# frozen_string_literal: true

require_relative "helpers"

class StructEqualityTest < Minitest::Test
  include CodegenTestHelpers

  def test_emits_struct_equality_helper_for_compared_struct
    source = <<~'MT'
      # module demo.seq_basic

      struct Vec2:
          x: float
          y: float

      function main() -> int:
          let a = Vec2(x = 1.0, y = 2.0)
          let b = Vec2(x = 1.0, y = 2.0)
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_struct_eq_demo_seq_basic_Vec2\(struct demo_seq_basic_Vec2 left, struct demo_seq_basic_Vec2 right\)/, generated)
    assert_match(/if \(left\.x != right\.x\) return false;/, generated)
    assert_match(/if \(left\.y != right\.y\) return false;/, generated)
    assert_match(/mt_struct_eq_demo_seq_basic_Vec2\(a, b\)/, generated,
                 "struct == must call the generated helper")
  end

  def test_emits_str_equality_dependency_for_str_field
    source = <<~'MT'
      # module demo.seq_str

      struct Labeled:
          name: str
          count: int

      function main() -> int:
          let a = Labeled(name = "x", count = 1)
          let b = Labeled(name = "x", count = 1)
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_str_equal/, generated,
                 "struct with str field must pull in mt_str_equal")
    assert_match(/if \(!mt_str_equal\(left\.name, right\.name\)\) return false;/, generated)
  end

  def test_emits_nested_struct_equality_dependency
    source = <<~'MT'
      # module demo.seq_nested

      struct Vec2:
          x: float
          y: float

      struct Labeled:
          name: str
          pos: Vec2

      function main() -> int:
          let a = Labeled(name = "x", pos = Vec2(x = 1.0, y = 2.0))
          let b = Labeled(name = "x", pos = Vec2(x = 1.0, y = 2.0))
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_struct_eq_demo_seq_nested_Vec2/, generated,
                 "nested struct field must get its own equality helper")
    assert_match(/if \(!mt_struct_eq_demo_seq_nested_Vec2\(left\.pos, right\.pos\)\) return false;/, generated)
  end

  def test_emits_element_wise_loop_for_array_field
    source = <<~'MT'
      # module demo.seq_array

      struct Packed:
          values: array[int, 3]
          count: int

      function main() -> int:
          let a = Packed(values = array[int, 3](1, 2, 3), count = 3)
          let b = Packed(values = array[int, 3](1, 2, 3), count = 3)
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/for \(uintptr_t index = 0; index < 3; index\+\+\)/, generated)
    assert_match(/if \(left\.values\[index\] != right\.values\[index\]\) return false;/, generated)
  end

  def test_emits_field_by_field_comparison_for_nullable_value_field
    source = <<~'MT'
      # module demo.seq_nullable

      struct Vec2:
          x: float
          y: float

      struct Maybe:
          point: Vec2?
          tag: ubyte

      function main() -> int:
          let a = Maybe(point = Vec2(x = 1.0, y = 2.0), tag = 7)
          let b = Maybe(point = null, tag = 7)
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/if \(left\.point\.has_value != right\.point\.has_value\) return false;/, generated)
    assert_match(/if \(left\.point\.has_value\) \{/, generated)
    assert_match(/if \(!mt_struct_eq_demo_seq_nullable_Vec2\(left\.point\.value, right\.point\.value\)\) return false;/, generated)
  end

  def test_emits_variant_equality_dependency_for_variant_field
    source = <<~'MT'
      # module demo.seq_variant

      variant Shape:
          circle(radius: float)
          square(side: float)

      struct Holder:
          shape: Shape
          label: str

      function main() -> int:
          let a = Holder(shape = Shape.circle(radius = 2.0), label = "a")
          let b = Holder(shape = Shape.circle(radius = 2.0), label = "a")
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_variant_eq_demo_seq_variant_Shape/, generated,
                 "variant-typed field must pull in the variant equality helper")
    assert_match(/if \(!mt_variant_eq_demo_seq_variant_Shape\(left\.shape, right\.shape\)\) return false;/, generated)
  end

  def test_does_not_emit_equality_helper_for_uncompared_structs
    source = <<~'MT'
      # module demo.seq_skip

      struct HasProc:
          cb: proc() -> int

      union RawUnion:
          i: int
          f: float

      struct HasUnion:
          raw: RawUnion

      struct Compared:
          value: int

      function main() -> int:
          let a = Compared(value = 1)
          let b = Compared(value = 1)
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/mt_struct_eq_demo_seq_skip_Compared/, generated)
    refute_match(/mt_struct_eq_demo_seq_skip_HasProc/, generated,
                 "uncompared struct with proc field must NOT get an equality helper")
    refute_match(/mt_struct_eq_demo_seq_skip_HasUnion/, generated,
                 "uncompared struct with union field must NOT get an equality helper")
    refute_match(/mt_struct_eq_demo_seq_skip_RawUnion/, generated,
                 "union must not get a struct equality helper")
  end

  def test_constant_folds_struct_equality
    source = <<~'MT'
      # module demo.seq_const

      struct Vec2:
          x: float
          y: float

      const A: Vec2 = Vec2(x = 1.0, y = 2.0)
      const B: Vec2 = Vec2(x = 1.0, y = 2.0)
      const C: Vec2 = Vec2(x = 1.0, y = 3.0)
      const EQ: bool = A == B
      const NE: bool = A != C

      function main() -> int:
          if EQ and NE:
              return 0
          return 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static const bool demo_seq_const_EQ = true;/, generated,
                 "== on struct consts must constant-fold to true")
    assert_match(/static const bool demo_seq_const_NE = true;/, generated,
                 "!= on differing struct consts must constant-fold to true")
    refute_match(/mt_struct_eq_demo_seq_const_Vec2/, generated,
                 "folded consts must not need a runtime equality helper")
  end

  def test_detects_struct_equality_nested_inside_binary_operand
    source = <<~'MT'
      # module demo.seq_nested_bin

      struct Vec2:
          x: float
          y: float

      function main() -> int:
          let a = Vec2(x = 1.0, y = 2.0)
          let b = Vec2(x = 1.0, y = 2.0)
          let eq = (a == b) or false
          if eq:
              return 0
          return 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_struct_eq_demo_seq_nested_bin_Vec2/, generated,
                 "struct equality nested inside a binary operand must still emit the helper")
  end

  def test_emits_struct_equality_dependency_for_variant_payload
    source = <<~'MT'
      # module demo.seq_var_struct

      struct Vec2:
          x: float
          y: float

      variant Holder:
          point(inner: Vec2)
          none

      function main() -> int:
          let a = Holder.point(inner = Vec2(x = 1.0, y = 2.0))
          let b = Holder.point(inner = Vec2(x = 1.0, y = 2.0))
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_variant_eq_demo_seq_var_struct_Holder/, generated)
    assert_match(/static bool mt_struct_eq_demo_seq_var_struct_Vec2/, generated,
                 "variant payload struct must get its own equality helper")
    assert_match(/if \(!mt_struct_eq_demo_seq_var_struct_Vec2\(left\.data\.point\.inner, right\.data\.point\.inner\)\) return false;/, generated)
  end

  def test_emits_element_wise_loop_for_variant_array_payload
    source = <<~'MT'
      # module demo.seq_var_array

      variant Shape:
          circle(radius: float)

      variant Holder:
          shapes(inner: array[Shape, 2])
          none

      function main() -> int:
          let a = Holder.shapes(inner = array[Shape, 2](Shape.circle(radius = 1.0), Shape.circle(radius = 2.0)))
          let b = Holder.shapes(inner = array[Shape, 2](Shape.circle(radius = 1.0), Shape.circle(radius = 2.0)))
          if a == b:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/for \(uintptr_t index = 0; index < 2; index\+\+\)/, generated)
    assert_match(/if \(!mt_variant_eq_demo_seq_var_array_Shape\(left\.data\.shapes\.inner\[index\], right\.data\.shapes\.inner\[index\]\)\) return false;/, generated)
  end

  def test_detects_variant_equality_nested_inside_binary_operand
    source = <<~'MT'
      # module demo.seq_var_nested_bin

      struct Vec2:
          x: float
          y: float

      variant Holder:
          point(inner: Vec2)
          none

      function main() -> int:
          let a = Holder.point(inner = Vec2(x = 1.0, y = 2.0))
          let b = Holder.point(inner = Vec2(x = 1.0, y = 2.0))
          let eq = (a == b) or false
          if eq:
              return 0
          return 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_variant_eq_demo_seq_var_nested_bin_Holder/, generated,
                 "variant equality nested inside a binary operand must still emit the helper")
    assert_match(/static bool mt_struct_eq_demo_seq_var_nested_bin_Vec2/, generated)
  end

  def test_constant_folds_variant_equality
    source = <<~'MT'
      # module demo.seq_var_const

      variant Shape:
          circle(radius: float)
          square(side: float)

      const A: Shape = Shape.circle(radius = 1.0)
      const B: Shape = Shape.circle(radius = 1.0)
      const C: Shape = Shape.square(side = 1.0)
      const EQ: bool = A == B
      const NE: bool = A != C

      function main() -> int:
          if EQ and NE:
              return 0
          return 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static const bool demo_seq_var_const_EQ = true;/, generated,
                 "== on variant consts with equal arms must constant-fold to true")
    assert_match(/static const bool demo_seq_var_const_NE = true;/, generated,
                 "!= on variant consts with different arms must constant-fold to true")
    refute_match(/mt_variant_eq_demo_seq_var_const_Shape/, generated,
                 "folded consts must not need a runtime equality helper")
  end

  def test_variant_payload_equality_uses_payload_struct_helper
    source = <<~'MT'
      # module demo.seq_payload

      variant Shape:
          circle(radius: float)
          square(side: float)

      function main() -> int:
          let a = Shape.circle(radius = 2.0)
          let b = Shape.circle(radius = 2.0)
          match a:
              Shape.circle as p:
                  match b:
                      Shape.circle as q:
                          if p == q:
                              return 0
                          return 1
                      else:
                          return 2
              else:
                  return 3
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_struct_eq_demo_seq_payload_Shape_circle\(struct demo_seq_payload_Shape_circle left, struct demo_seq_payload_Shape_circle right\)/, generated,
                 "payload comparison must use a struct-style helper over the payload struct")
    assert_match(/if \(left\.radius != right\.radius\) return false;/, generated)
    refute_match(/mt_variant_eq_demo_seq_payload_Shape\(left/, generated,
                 "payload comparison must NOT pass payload structs to the variant helper")
  end

  def test_cyclic_variant_field_compares_by_pointer_identity
    source = <<~'MT'
      # module demo.seq_cyclic

      variant Expr:
          literal(value: int)
          binary_op(operator: str, left: Expr, right: Expr)

      function main() -> int:
          let a = Expr.binary_op(operator = "+", left = Expr.literal(value = 1), right = Expr.literal(value = 2))
          let b = Expr.binary_op(operator = "+", left = Expr.literal(value = 1), right = Expr.literal(value = 2))
          if a == b:
              return 0
          return 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_variant_eq_demo_seq_cyclic_Expr/, generated)
    assert_match(/if \(!mt_str_equal\(left\.data\.binary_op\.operator, right\.data\.binary_op\.operator\)\) return false;/, generated)
    assert_match(/if \(left\.data\.binary_op\.left != right\.data\.binary_op\.left\) return false;/, generated,
                 "cyclic field must compare by pointer identity (C field is a pointer)")
    assert_match(/if \(left\.data\.binary_op\.right != right\.data\.binary_op\.right\) return false;/, generated)
    refute_match(/mt_variant_eq_demo_seq_cyclic_Expr\(left\.data\.binary_op\.left/, generated,
                 "cyclic field must NOT recurse into the variant helper")
  end

  def test_run_program_with_cyclic_variant_pointer_identity
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      variant Expr:
          literal(value: int)
          binary_op(operator: str, left: Expr, right: Expr)

      function main() -> int:
          # Literal arm has no cyclic fields: value comparison succeeds.
          let a = Expr.literal(value = 1)
          let b = Expr.literal(value = 1)
          if a == b:
              pass
          else:
              return 1

          # Binary op arms embed heap-allocated children as pointers:
          # pointer identity means separately-built trees are unequal.
          let c = Expr.binary_op(operator = "+", left = Expr.literal(value = 1), right = Expr.literal(value = 2))
          let d = Expr.binary_op(operator = "+", left = Expr.literal(value = 1), right = Expr.literal(value = 2))
          if c != d:
              pass
          else:
              return 2

          # The same value compared to itself is equal.
          if c == c:
              pass
          else:
              return 3

          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_cyclic_variant_through_generic_option_compares_by_pointer_identity
    source = <<~'MT'
      # module demo.seq_cyclic_option

      variant Expr:
          literal(value: int)
          cond(test: Expr, else_b: Option[Expr])

      function main() -> int:
          let a = Expr.cond(test = Expr.literal(value = 1), else_b = Option[Expr].none)
          let b = Expr.cond(test = Expr.literal(value = 1), else_b = Option[Expr].none)
          if a == a:
              pass
          else:
              return 1
          if a != b:
              pass
          else:
              return 2
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_variant_eq_demo_seq_cyclic_option_Expr/, generated)
    assert_match(/if \(left\.data\.cond\.test != right\.data\.cond\.test\) return false;/, generated,
                 "direct cyclic field must compare by pointer identity")
    assert_match(/if \(left\.data\.cond\.else_b != right\.data\.cond\.else_b\) return false;/, generated,
                 "cycle through Option[Expr] must also compare by pointer identity")
  end

  def test_mutually_recursive_variant_equality
    source = <<~'MT'
      # module demo.seq_mutual

      variant Expr:
          literal(value: int)
          block_stmts(stmts: Stmt)

      variant Stmt:
          expr_stmt(e: Expr)
          nop

      function main() -> int:
          let a = Expr.literal(value = 1)
          if a == a:
              pass
          else:
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static bool mt_variant_eq_demo_seq_mutual_Expr/, generated)
    assert_match(/if \(left\.data\.block_stmts\.stmts != right\.data\.block_stmts\.stmts\) return false;/, generated,
                 "mutually recursive variant field must compare by pointer identity")
    assert_match(/static bool mt_variant_eq_demo_seq_mutual_Stmt/, generated)
  end

  def test_run_program_with_struct_equality
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      struct Vec2:
          x: float
          y: float

      struct Labeled:
          name: str
          pos: Vec2

      struct Packed:
          values: array[int, 3]
          count: int

      struct Maybe:
          point: Vec2?
          tag: ubyte

      variant Shape:
          circle(radius: float)
          square(side: float)

      struct Holder:
          shape: Shape
          label: str

      function main() -> int:
          let a = Vec2(x = 1.0, y = 2.0)
          let b = Vec2(x = 1.0, y = 2.0)
          let c = Vec2(x = 1.0, y = 3.0)
          if a == b:
              pass
          else:
              return 1
          if a != c:
              pass
          else:
              return 2

          let la = Labeled(name = "x", pos = a)
          let lb = Labeled(name = "x", pos = b)
          if la == lb:
              pass
          else:
              return 3

          let pa = Packed(values = array[int, 3](1, 2, 3), count = 3)
          let pb = Packed(values = array[int, 3](1, 2, 3), count = 3)
          if pa == pb:
              pass
          else:
              return 4

          let ma = Maybe(point = a, tag = 7)
          let mb = Maybe(point = b, tag = 7)
          let mc = Maybe(point = null, tag = 7)
          if ma == mb:
              pass
          else:
              return 5
          if ma != mc:
              pass
          else:
              return 6

          let ha = Holder(shape = Shape.circle(radius = 2.0), label = "a")
          let hb = Holder(shape = Shape.circle(radius = 2.0), label = "a")
          let hc = Holder(shape = Shape.square(side = 2.0), label = "a")
          if ha == hb:
              pass
          else:
              return 7
          if ha != hc:
              pass
          else:
              return 8

          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end
end
