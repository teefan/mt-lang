# frozen_string_literal: true

require_relative "../semantic/helpers"
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
              work_a()
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
              return 0
              pass
          return 0
    MT

    error = assert_raises(MilkTea::SemanticError) { check_program_source(source) }
    assert_match(/return.*not allowed/, error.message)
  end

  def test_parallel_block_generates_c_with_spawn_all
    source = <<~MT
      # module demo.pblock_gen

      function use_value(x: int) -> void:
          pass

      function main() -> int:
          var n = 42
          parallel:
              use_value(n)
              use_value(n)
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_spawn_all"
    assert_includes c_code, "mt_spawn_work_"
    assert_includes c_code, "mt_spawn_cap_"
    assert_includes c_code, "mt_spawn_item"
  end

  def test_captureless_block_has_no_capture_struct
    source = <<~MT
      # module demo.pblock_nocap

      function work_a() -> void:
          pass

      function work_b() -> void:
          pass

      function main() -> int:
          parallel:
              work_a()
              work_b()
          return 0
    MT

    c_code = generate_c_from_program_source(source)
    assert_includes c_code, "mt_spawn_all"
    refute_match(/struct mt_spawn_cap.*\{\s*\}/, c_code)
  end
end
