# frozen_string_literal: true

require_relative "../sema/helpers"
require_relative "helpers"

class ParallelBlockTest < Minitest::Test
  include SemaTestHelpers
  include CodegenTestHelpers

  def test_parallel_block_parses_and_type_checks
    source = <<~MT
      # module demo.pblock

      function work_a() -> void:
          pass

      function work_b() -> void:
          pass

      function main() -> int:
          parallel:
              spawn:
                  work_a()
              spawn:
                  work_b()
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_parallel_block_rejects_return_in_spawn
    source = <<~MT
      # module demo.pblock_ret

      function main() -> int:
          parallel:
              spawn:
                  return 0
              spawn:
                  pass
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_program_source(source) }
    assert_match(/return.*not allowed/, error.message)
  end

  def test_parallel_block_generates_c_with_spawn_all
    source = <<~MT
      # module demo.pblock_gen

      function work_a() -> void:
          pass

      function work_b() -> void:
          pass

      function main() -> int:
          parallel:
              spawn:
                  work_a()
              spawn:
                  work_b()
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_spawn_all"
    assert_includes c_code, "mt_spawn_work_"
    assert_includes c_code, "mt_spawn_cap_"
    assert_includes c_code, "mt_spawn_item"
  end
end
