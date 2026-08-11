# frozen_string_literal: true

require_relative "helpers"

class MatchTest < Minitest::Test
  include CodegenTestHelpers

  def test_run_mixed_inline_then_block_match_arms
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      var count: int = 0

      function bump() -> void:
          count += 1

      function classify(n: int) -> int:
          match n:
              0: bump()
              1:
                  return 20
              _: bump()
          return count

      function main() -> int:
          let a = classify(0)
          let b = classify(1)
          let c = classify(5)
          return a + b + c
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 23, result.exit_status
  end

  def test_run_mixed_block_then_inline_match_arms
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      var count: int = 0

      function bump() -> void:
          count += 1

      function classify(n: int) -> int:
          match n:
              0:
                  return 10
              1: bump()
              _:
                  return 30
          return count

      function main() -> int:
          let a = classify(0)
          let b = classify(1)
          let c = classify(9)
          return a + b + c
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 41, result.exit_status
  end

  def test_run_mixed_arms_with_variant_payload_binding
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      variant Token:
          number(value: int)
          eof

      var total: int = 0

      function add_to_total(v: int) -> void:
          total += v

      function main() -> int:
          let t = Token.number(value = 7)
          match t:
              Token.number as n: add_to_total(n.value)
              Token.eof:
                  return 0
          return total
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
  end
end
