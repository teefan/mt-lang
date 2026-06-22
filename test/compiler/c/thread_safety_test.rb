# frozen_string_literal: true

require_relative "../semantic/helpers"
require_relative "helpers"

class ThreadSafetyTest < Minitest::Test
  include SemaTestHelpers
  include CodegenTestHelpers

  def test_parallel_for_rejects_ref_capture
    source = <<~MT
      # module demo.safety_ref_pfor

      function bad(r: ref[int], count: int) -> void:
          parallel for i in 0..count:
              let x = read(r)
    MT

    error = assert_raises(MilkTea::LoweringError) { generate_c_from_program_source(source) }
    assert_match(/ref.*not safe.*thread/, error.message)
  end

  def test_parallel_block_rejects_ref_capture
    source = <<~MT
      # module demo.safety_ref_pblock

      function noop(r: ref[int]) -> void:
          pass

      function bad(r: ref[int]) -> void:
          parallel:
              noop(r)
              pass
    MT

    error = assert_raises(MilkTea::LoweringError) { generate_c_from_program_source(source) }
    assert_match(/ref.*not safe.*thread/, error.message)
  end

  def test_parallel_block_rejects_write_conflict
    source = <<~MT
      # module demo.safety_conflict

      var shared: int = 0

      function main() -> int:
          var x = 0
          parallel:
              x = 1
              x = 2
          return x
    MT

    error = assert_raises(MilkTea::LoweringError) { generate_c_from_program_source(source) }
    assert_match(/write conflict/, error.message)
  end

  def test_parallel_block_allows_disjoint_writes
    source = <<~MT
      # module demo.safety_disjoint

      function main() -> int:
          var a = 0
          var b = 0
          parallel:
              a = 1
              b = 2
          return a + b
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_spawn_all"
  end

  def test_parallel_block_allows_shared_reads
    source = <<~MT
      # module demo.safety_shared_read

      function use(x: int) -> void:
          pass

      function main() -> int:
          let value = 42
          parallel:
              use(value)
              use(value)
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_spawn_all"
  end

  def test_parallel_block_rejects_write_read_conflict
    source = <<~MT
      # module demo.safety_wr_conflict

      function use(x: int) -> void:
          pass

      function main() -> int:
          var x = 0
          parallel:
              x = 1
              use(x)
          return x
    MT

    error = assert_raises(MilkTea::LoweringError) { generate_c_from_program_source(source) }
    assert_match(/write conflict/, error.message)
  end

  def test_parallel_for_allows_span_capture
    source = <<~MT
      # module demo.safety_span

      function fill(data: span[int], count: int) -> void:
          parallel for i in 0..count:
              data[i] = int<-i

      function main() -> int:
          var buf: array[int, 10]
          fill(buf.as_span(), 10)
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_parallel_for"
  end

  def test_parallel_for_allows_scalar_capture
    source = <<~MT
      # module demo.safety_scalar

      function fill(data: span[int], count: int, multiplier: int) -> void:
          parallel for i in 0..count:
              data[i] = int<-i * multiplier

      function main() -> int:
          var buf: array[int, 10]
          fill(buf.as_span(), 10, 3)
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_parallel_for"
  end
end
