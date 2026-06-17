# frozen_string_literal: true

require_relative "../sema/helpers"
require_relative "helpers"

class ParallelForTest < Minitest::Test
  include SemaTestHelpers
  include CodegenTestHelpers

  def test_parallel_for_parses_and_type_checks
    source = <<~MT
      # module demo.pfor

      function main() -> int:
          var buf: array[int, 100]
          parallel for i in 0..100:
              buf[i] = int<-i * 2
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_parallel_for_rejects_collection_iteration
    source = <<~MT
      # module demo.pfor_col

      function main() -> int:
          var items: array[int, 10]
          parallel for item in items:
              pass
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/range/, error.message)
  end

  def test_parallel_for_rejects_break
    source = <<~MT
      # module demo.pfor_break

      function main() -> int:
          parallel for i in 0..10:
              break
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/break.*not allowed.*parallel/, error.message)
  end

  def test_parallel_for_rejects_continue
    source = <<~MT
      # module demo.pfor_continue

      function main() -> int:
          parallel for i in 0..10:
              continue
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/continue.*not allowed.*parallel/, error.message)
  end

  def test_parallel_for_rejects_return
    source = <<~MT
      # module demo.pfor_return

      function main() -> int:
          parallel for i in 0..10:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/return.*not allowed.*parallel/, error.message)
  end

  def test_parallel_for_rejects_defer
    source = <<~MT
      # module demo.pfor_defer

      function helper() -> void:
          pass

      function main() -> int:
          parallel for i in 0..10:
              defer helper()
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/defer.*not allowed.*parallel/, error.message)
  end

  def test_parallel_for_generates_c_with_worker_and_dispatch
    source = <<~MT
      # module demo.pfor_gen

      function main() -> int:
          var buf: array[int, 100]
          let count = 100
          parallel for i in 0..count:
              buf[i] = int<-i * 2
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_parallel_for"
    assert_includes c_code, "mt_pfor_work_"
    assert_includes c_code, "mt_pfor_cap_"
    assert_includes c_code, "uv.h"
  end
end
