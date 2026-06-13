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
end
