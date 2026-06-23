# frozen_string_literal: true

require_relative "../test_helper"
require_relative "semantic/helpers"

class TestLowerer < MilkTea::Lowerer
  def lower
    @recorded_expr_types = {}
    @bypass_sema_type_cache = true
    super
  end

  def infer_expression_type(expression, env:, expected_type: nil)
    type = super
    if (node_id = @ctx.ast.node_ids[expression.object_id])
      @recorded_expr_types[node_id] = type
    end
    type
  end
end

class SemaLoweringTypeConsistencyTest < Minitest::Test
  include SemaTestHelpers

  def types_equivalent?(a, b)
    return true if a == b
    return true if a.class == b.class && a.respond_to?(:name) && a.name == b.name
    return true if a.is_a?(MilkTea::Types::Null) && (b.is_a?(MilkTea::Types::Nullable) || b.is_a?(MilkTea::Types::Pointer))
    return true if b.is_a?(MilkTea::Types::Null) && (a.is_a?(MilkTea::Types::Nullable) || a.is_a?(MilkTea::Types::Pointer))
    return true if a.class == b.class && a.respond_to?(:element_types) &&
      a.element_types.length == b.element_types.length &&
      a.element_types.zip(b.element_types).all? { |ea, eb| types_equivalent?(ea, eb) }

    false
  end

  def assert_type_consistency(source, imported_sources: {})
    program = check_program_source(source, imported_sources)
    analysis = program.root_analysis

    lowerer = TestLowerer.new(program)
    lowerer.lower
    recorded = lowerer.instance_variable_get(:@recorded_expr_types)
    sema_types = analysis.resolved_expr_types

    mismatches = []
    recorded.each do |node_id, lowering_type|
      sema_type = sema_types[node_id]
      next if sema_type.nil?
      next if types_equivalent?(sema_type, lowering_type)

      mismatches << "node_id=#{node_id} sema=#{sema_type} lowering=#{lowering_type}"
    end

    assert mismatches.empty?, "#{mismatches.length} type mismatches:\n#{mismatches.join("\n")}"
  end

  def test_integer_literals_match
    assert_type_consistency(<<~MT)
      const A: int = 42
      const B: uint = 42u
      const C: byte = 7
      const D: long = -1l
    MT
  end

  def test_float_literals_match
    assert_type_consistency(<<~MT)
      const A: float = 1.0f
      const B: double = 1.0d
      const C: float = 3.14
      const D: double = 1.2e-3
    MT
  end

  def test_char_and_bool_literals_match
    assert_type_consistency(<<~MT)
      const A: ubyte = 'a'
      const B: ubyte = '\\n'
      const C: bool = true
      const D: bool = false
    MT
  end

  def test_string_literals_match
    assert_type_consistency(<<~MT)
      const A: str = "hello"
      const B: cstr = c"hello"
    MT
  end

  def test_null_literals_match
    assert_type_consistency(<<~MT)
      const A: ptr[int]? = null
    MT
  end

  def test_arithmetic_binary_types_match
    assert_type_consistency(<<~MT)
      const A: int = 1 + 2
      const B: int = 3 - 1
      const C: int = 4 * 5
      const D: int = 10 / 3
      const E: int = 10 % 3
      const F: float = 1.0 + 2.0
    MT
  end

  def test_comparison_types_match
    assert_type_consistency(<<~MT)
      const A: bool = 1 == 2
      const B: bool = 1 != 2
      const C: bool = 1 < 2
      const D: bool = 1 > 2
      const E: bool = 1 <= 2
      const F: bool = 1 >= 2
    MT
  end

  def test_bitwise_types_match
    assert_type_consistency(<<~MT)
      const A: int = 1 | 2
      const B: int = 1 & 3
      const C: int = 1 ^ 3
      const D: int = 1 << 2
      const E: int = 8 >> 1
    MT
  end

  def test_logical_types_match
    assert_type_consistency(<<~MT)
      const A: bool = true and false
      const B: bool = true or false
      const C: bool = not true
    MT
  end

  def test_sizeof_alignof_types_match
    assert_type_consistency(<<~MT)
      struct Vec2:
          x: float
          y: float

      const A: ptr_uint = size_of(float)
      const B: ptr_uint = align_of(Vec2)
    MT
  end

  def test_tuple_literals_match
    assert_type_consistency(<<~MT)
      const A: (int, bool) = (42, true)
    MT
  end

  def test_struct_constructor_types_match
    assert_type_consistency(<<~MT)
      struct Vec2:
          x: float
          y: float

      const ORIGIN: Vec2 = Vec2(x = 0.0, y = 0.0)
    MT
  end

  def test_enum_member_types_match
    assert_type_consistency(<<~MT)
      enum State: ubyte
          idle = 0
          running = 1

      const S: State = State.running
    MT
  end

  def test_variant_ctor_types_match
    assert_type_consistency(<<~MT)
      variant Maybe[T]:
          just(value: T)
          nothing

      const VAL: Maybe[int] = Maybe[int].just(value = 42)
    MT
  end

  def test_function_call_types_match
    assert_type_consistency(<<~MT)
      const function square(x: int) -> int:
          return x * x

      const S: int = square(5)
    MT
  end

  def test_type_cast_types_match
    assert_type_consistency(<<~MT)
      const A: float = float<-5
    MT
  end

  def test_default_builtin_types_match
    assert_type_consistency(<<~MT)
      struct Counter:
          value: int

      extending Counter:
          static function default() -> Counter:
              return Counter(value = 0)

      const A: Counter = default[Counter]
    MT
  end

  def test_function_local_expression_types_match
    assert_type_consistency(<<~MT)
      function main() -> int:
          let x: int = 42
          let y: bool = x > 0
          let z: float = 3.14
          return 0
    MT
  end

  def test_match_expression_types_match
    assert_type_consistency(<<~MT)
      function main() -> int:
          let label = match 1:
              1: "one"
              _: "other"
          return 0
    MT
  end

  def test_if_expression_types_match
    assert_type_consistency(<<~MT)
      const A: int = if true: 1 else: 2
    MT
  end

  def test_vector_constructor_types_match
    assert_type_consistency(<<~MT)
      const V: vec3 = vec3(x = 1.0, y = 2.0, z = 3.0)
    MT
  end

  def test_mixed_int_float_binary_types_match
    assert_type_consistency(<<~MT)
      const A: float = 1 + 2.0
      const B: float = 1.0 + 2
      const C: float = 1.0f + 1
    MT
  end
end
