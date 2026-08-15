# frozen_string_literal: true

require_relative "helpers"

class TupleTest < Minitest::Test
  include CodegenTestHelpers

  def test_run_program_with_basic_tuple
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function main() -> int:
          let t = (42, 7)
          return t._0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
  end

  def test_run_program_with_tuple_member_access
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function main() -> int:
          let t = (10, 20, 30)
          return t._1 + t._2
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 50, result.exit_status
  end

  def test_run_program_with_tuple_return
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function pair() -> (int, str):
          return (42, "hello")
      function main() -> int:
          let p = pair()
          return p._0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
  end

  def test_run_program_with_named_tuple
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function main() -> int:
          let t = (x = 10, y = 20)
          return t.x + t.y
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 30, result.exit_status
  end

  def test_run_program_with_destructure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function pair() -> (int, str):
          return (42, "hello")
      function main() -> int:
          let (a, b) = pair()
          return a
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
  end

  def test_run_program_with_destructure_swap
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      function main() -> int:
          var a = 1
          var b = 2
          var t = (a, b)
          let (x, y) = t
          return x + y
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
  end

  def test_run_program_with_struct_destructure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      struct Point:
          x: int
          y: int

      function main() -> int:
          var pt = Point(x = 3, y = 4)
          let Point(x, y) = pt
          return x + y
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
  end

  def test_run_program_with_struct_destructure_partial
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      struct Vec3:
          x: float
          y: float
          z: float

      function main() -> int:
          var v = Vec3(x = 1.0, y = 2.0, z = 3.0)
          let Vec3(x, y, z) = v
          return int<-(x + y + z)
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 6, result.exit_status
  end

  def test_run_program_with_const_tuple_array
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      const PAIRS: array[(int, int), 2] = ((1, 2), (3, 4))

      function main() -> int:
          var total = 0
          for entry in PAIRS:
              total += entry._0 + entry._1
          return total
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  def test_run_program_with_const_struct_field_of_tuple
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      struct WithTuple:
          point: (int, int)
          tag: int

      const S: WithTuple = WithTuple(point = (7, 8), tag = 9)

      function main() -> int:
          return S.point._0 + S.point._1 + S.tag
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 24, result.exit_status
  end

  def test_run_program_with_global_tuple_array
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      var GLOBAL_ARRAY: array[(int, int), 2]

      function main() -> int:
          GLOBAL_ARRAY[0] = (1, 2)
          GLOBAL_ARRAY[1] = (3, 4)
          var total = 0
          for entry in GLOBAL_ARRAY:
              total += entry._0 + entry._1
          return total
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
  end

  def test_run_program_with_vec_of_tuples
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    # Tuples in a generic container force heap.resize[T] specialization, whose
    # body calls align_of(T)/size_of(T).  sized_layout_type? must accept the
    # tuple element type or specialization fails at check time.
    source = <<~'MT'
      import std.vec as vec

      function main() -> int:
          var v = vec.Vec[(int, int)].create()
          v.push((1, 2))
          v.push((3, 4))
          var total = 0
          let first = v.get(0)
          if first != null:
              total += 1
          return total
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 1, result.exit_status
  end
end
