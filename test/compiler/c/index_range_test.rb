# frozen_string_literal: true

require_relative "helpers"

class IndexRangeTest < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_for_str_index_and_range_slice
    source = <<~MT
      # module demo.str_index_slice

      function main() -> int:
          let text: str = "hello world"
          let first = text[0]
          let head = text[0..5]
          let tail = text[6..text.len]
          if first != 104:
              return 1
          if head != "hello":
              return 2
          if tail != "world":
              return 3
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/static uint8_t mt_str_index\(mt_str text, uintptr_t index\)/, generated)
    assert_match(/if \(index >= text\.len\) mt_fatal\("str index out of bounds"\);/, generated)
    assert_match(/static mt_str mt_str_slice\(mt_str text, uintptr_t start, uintptr_t stop\)/, generated)
    assert_match(/if \(start > stop \|\| stop > text\.len\) mt_fatal\("str slice out of bounds"\);/, generated)
    assert_match(/str slice bounds must be UTF-8 code-unit boundaries/, generated)
    assert_match(/uint8_t first = mt_str_index\(text, 0\);/, generated)
    assert_match(/mt_str head = mt_str_slice\(text, 0, 5\);/, generated)
    assert_match(/mt_str tail = mt_str_slice\(text, 6, text\.len\);/, generated)
  end

  def test_generate_c_for_array_and_span_range_slice
    source = <<~MT
      # module demo.span_range_slice

      function half(items: span[int]) -> span[int]:
          return items[1..3]

      function main() -> int:
          var values: array[int, 4] = (10, 20, 30, 40)
          let view = values[0..2]
          let part = half(values)
          if view.len != 2:
              return 1
          if part[0] != 20 or part[1] != 30:
              return 2
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/static inline mt_span_int mt_span_slice_int\(mt_span_int span, uintptr_t start, uintptr_t stop\)/, generated)
    assert_match(/if \(start > stop \|\| stop > span\.len\) mt_fatal\("span slice out of bounds"\);/, generated)
    assert_match(/return mt_span_slice_int\(items, 1, 3\);/, generated)
    assert_match(/mt_span_int view = mt_span_slice_int\(\(mt_span_int\)\{ \.data = &values\[0\], \.len = 4 \}, 0, 2\);/, generated)
  end

  def test_generate_c_omits_slice_helpers_when_unused
    source = <<~MT
      # module demo.no_slice

      function main() -> int:
          let text: str = "hello"
          return int<-text.len
    MT

    generated = generate_c_from_source(source)

    refute_match(/mt_str_slice/, generated)
    refute_match(/mt_str_index/, generated)
    refute_match(/mt_span_slice/, generated)
  end

  def test_rejects_range_index_with_non_integer_bounds
    source = <<~MT
      # module demo.range_float_bounds

      function main() -> int:
          let text: str = "hello"
          let bad = text[0.0..2.0]
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/range index bounds must be integer types/, error.message)
  end

  def test_rejects_array_range_slice_with_negative_literal_bound
    source = <<~MT
      # module demo.slice_neg_lit_bound

      function main() -> int:
          var values: array[int, 4] = (10, 20, 30, 40)
          let sub = values[-1..2]
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/range index \[-1\.\.2\] is out of bounds for array/, error.message)
  end

  def test_run_program_for_index_and_range_slices
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.slice_run

      function sum(items: span[uint]) -> uint:
          var total: uint = 0
          for i in 0..items.len:
              total += items[i]
          return total

      function main() -> int:
          let text: str = "hello world"
          var values: array[uint, 5] = (1, 2, 3, 4, 5)
          if text[0] != 104:
              return 1
          if text[4] != 111:
              return 2
          let empty = text[3..3]
          if empty != "":
              return 3
          let shifted = text[2..text.len]
          if shifted != "llo world":
              return 4
          if sum(values[1..4]) != 9:
              return 5
          if sum(values[0..5]) != 15:
              return 6
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_run_program_str_slice_out_of_bounds_aborts
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.slice_oob

      function main() -> int:
          let text: str = "hello"
          let bad = text[3..9]
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    refute_equal 0, result.exit_status
    assert_match(/str slice out of bounds/, result.stderr)
  end

  def test_run_program_str_slice_utf8_boundary_aborts
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.slice_utf8

      function main() -> int:
          let text: str = "héllo"
          let bad = text[1..2]
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    refute_equal 0, result.exit_status
    assert_match(/UTF-8 code-unit boundaries/, result.stderr)
  end

  def test_run_program_span_slice_out_of_bounds_aborts
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT
      # module demo.span_slice_oob

      function main() -> int:
          var values: array[int, 3] = (1, 2, 3)
          var stop: int = 5
          let bad = values[2..stop]
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    refute_equal 0, result.exit_status
    assert_match(/span slice out of bounds/, result.stderr)
  end

  def test_rejects_str_index_assignment
    source = <<~MT
      # module demo.str_index_assign

      function main() -> int:
          var text: str = "hello"
          text[0] = 72
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/cannot assign through str index; str is an immutable borrowed view/, error.message)
  end

  def test_rejects_str_range_index_assignment
    source = <<~MT
      # module demo.str_range_assign

      function main() -> int:
          var text: str = "hello"
          text[0..2] = (72, 73)
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/cannot assign through str index; str is an immutable borrowed view/, error.message)
  end

  def test_rejects_array_range_slice_with_out_of_bounds_literals
    source = <<~MT
      # module demo.array_slice_oob

      function main() -> int:
          let values: array[int, 3] = (1, 2, 3)
          let bad = values[2..5]
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/range index \[2\.\.5\] is out of bounds for array\[T, 3\]/, error.message)
  end

  def test_rejects_array_range_slice_of_temporary
    source = <<~MT
      # module demo.array_slice_temporary

      function make() -> array[int, 3]:
          return array[int, 3](1, 2, 3)

      function main() -> int:
          let bad = make()[0..2]
          return bad.len
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/array range slice requires an addressable array value; bind it to a local first/, error.message)
  end

  def test_rejects_range_index_on_unsupported_receiver
    source = <<~MT
      # module demo.range_unsupported

      function main() -> int:
          let value: int = 42
          let bad = value[0..1]
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/cannot range-index int; expected str, array\[T, N\], or span\[T\]/, error.message)
  end

  def test_rejects_str_byte_index_with_negative_literal
    source = <<~MT
      # module demo.str_negative_literal

      function main() -> int:
          let text: str = "hello"
          let b = text[-1]
          return int<-b
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/str index -1 is negative/, error.message)
  end

  def test_rejects_array_range_slice_with_negative_literal_bound
    source = <<~MT
      # module demo.array_negative_literal_bound

      function main() -> int:
          var values: array[int, 4] = (10, 20, 30, 40)
          let sub = values[-1..2]
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) do
      generate_c_from_source(source)
    end

    assert_match(/range index \[-1\.\.2\] is out of bounds for array\[T, 4\]/, error.message)
  end
end
