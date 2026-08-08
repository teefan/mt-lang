# frozen_string_literal: true

require_relative "helpers"

class StructEqualityTest < Minitest::Test
  include SemaTestHelpers

  def test_struct_equality_type_checks_with_primitive_fields
    source = <<~MT
      # module demo.struct_eq_prims

      struct Vec2:
          x: float
          y: float

      function main() -> int:
          let a = Vec2(x = 1.0, y = 2.0)
          let b = Vec2(x = 1.0, y = 2.0)
          if a == b:
              return 1
          if a != b:
              return 2
          return 0
    MT

    check_program_source(source)
  end

  def test_struct_equality_type_checks_with_str_and_nested_struct_fields
    source = <<~MT
      # module demo.struct_eq_nested

      struct Vec2:
          x: float
          y: float

      struct Labeled:
          name: str
          pos: Vec2

      function main() -> int:
          let a = Labeled(name = "a", pos = Vec2(x = 1.0, y = 2.0))
          let b = Labeled(name = "a", pos = Vec2(x = 1.0, y = 2.0))
          if a == b:
              return 1
          return 0
    MT

    check_program_source(source)
  end

  def test_struct_equality_type_checks_with_array_field
    source = <<~MT
      # module demo.struct_eq_array

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

    check_program_source(source)
  end

  def test_struct_equality_type_checks_with_variant_field
    source = <<~MT
      # module demo.struct_eq_variant

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

    check_program_source(source)
  end

  def test_struct_equality_type_checks_with_nullable_value_field
    source = <<~MT
      # module demo.struct_eq_nullable

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

    check_program_source(source)
  end

  def test_struct_equality_type_checks_with_generic_instance
    source = <<~MT
      # module demo.struct_eq_generic

      struct Pair[A, B]:
          first: A
          second: B

      function main() -> int:
          let a = Pair[int, float](first = 1, second = 2.0)
          let b = Pair[int, float](first = 1, second = 2.0)
          if a == b:
              return 1
          return 0
    MT

    check_program_source(source)
  end

  def test_rejects_struct_equality_with_union_field
    source = <<~MT
      # module demo.struct_eq_union

      union RawUnion:
          i: int
          f: float

      struct HasUnion:
          raw: RawUnion

      function main() -> int:
          let a = HasUnion(raw = RawUnion(i = 1))
          if a == a:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/operator == is not supported for struct type .*HasUnion/, error.message)
    assert_match(/field 'raw' of type .*RawUnion is not equality-comparable/, error.message)
    assert_match(/use equal\[.*HasUnion\]\(\.\.\.\) instead/, error.message)
  end

  def test_rejects_struct_equality_with_proc_field
    source = <<~MT
      # module demo.struct_eq_proc

      struct HasProc:
          cb: proc() -> int

      function main() -> int:
          let p = HasProc(cb = proc() -> int: 0)
          if p == p:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/field 'cb' of type proc\(\) -> int is not equality-comparable/, error.message)
  end

  def test_rejects_struct_equality_with_span_field
    source = <<~MT
      # module demo.struct_eq_span

      struct HasSpan:
          data: span[int]

      function main() -> int:
          var backing: int = 0
          let sp = HasSpan(data = span[int](data = ptr_of(backing), len = 0))
          if sp == sp:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/field 'data' of type span\[int\] is not equality-comparable/, error.message)
  end

  def test_rejects_union_equality_directly
    source = <<~MT
      # module demo.union_eq

      union RawUnion:
          i: int
          f: float

      function main() -> int:
          let a = RawUnion(i = 1)
          let b = RawUnion(i = 1)
          if a == b:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/operator == is not supported for union type .*RawUnion/, error.message)
  end

  def test_cyclic_variant_equality_type_checks
    source = <<~MT
      # module demo.variant_cyclic

      variant Expr:
          literal(value: int)
          binary_op(operator: str, left: Expr, right: Expr)

      function main() -> int:
          let a = Expr.literal(value = 1)
          if a == a:
              return 1
          return 0
    MT

    check_program_source(source)
  end

  def test_rejects_variant_equality_with_proc_payload
    source = <<~MT
      # module demo.variant_proc

      variant Bad:
          cb(call: proc() -> int)

      function main() -> int:
          let a = Bad.cb(call = proc() -> int: 0)
          if a == a:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/arm 'cb' field 'call' of type proc\(\) -> int is not equality-comparable/, error.message)
  end

  def test_variant_equality_type_checks_with_comparable_generic_payload
    source = <<~MT
      # module demo.variant_option_eq

      function main() -> int:
          let a = Option[int].some(value = 1)
          let b = Option[int].some(value = 1)
          if a == b:
              return 1
          return 0
    MT

    check_program_source(source)
  end

  def test_rejects_struct_equality_with_non_comparable_value_nullable_field
    source = <<~MT
      # module demo.struct_eq_nullable_span

      struct HasSpanOpt:
          data: span[int]?

      function main() -> int:
          var backing: int = 0
          let sp = HasSpanOpt(data = span[int](data = ptr_of(backing), len = 0))
          if sp == sp:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      check_program_source(source)
    end

    assert_match(/field 'data' of type span\[int\]\? is not equality-comparable/, error.message)
  end

  def test_struct_equality_type_checks_with_nullable_span_of_comparable_struct
    source = <<~MT
      # module demo.struct_eq_nullable_variant

      variant Shape:
          circle(radius: float)

      struct Holder:
          maybe_shape: Shape?
          tag: int

      function main() -> int:
          let a = Holder(maybe_shape = Shape.circle(radius = 1.0), tag = 1)
          let b = Holder(maybe_shape = null, tag = 1)
          if a == b:
              return 1
          return 0
    MT

    check_program_source(source)
  end
end
