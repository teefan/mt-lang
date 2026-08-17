# frozen_string_literal: true

require_relative "../semantic/helpers"
require_relative "helpers"

class ComptimeFoldTest < Minitest::Test
  include SemaTestHelpers
  include CodegenTestHelpers

  def test_comptime_folds_string_concat_to_literal
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_concat

      const GREET: str = "hello" + " " + "world"

      function main() -> int:
          return 0
    MT

    assert_includes c_code, '.data = "hello world"'
    refute_includes c_code, "mt_str_concat"
  end

  def test_comptime_folds_string_concat_in_block_body
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_concat_block

      const CONCAT_BLOCK -> str:
          var s: str = "x"
          s += "y"
          s += "z"
          return s

      function main() -> int:
          return 0
    MT

    assert_includes c_code, '.data = "xyz"'
    refute_includes c_code, "mt_str_concat"
  end

  def test_comptime_folds_break_and_continue
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_loop

      const SUM -> int:
          var total: int = 0
          for i in 0..10:
              if i == 3:
                  continue
              if i >= 6:
                  break
              total += i
          return total

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_loop_SUM = 12"
  end

  def test_comptime_folds_while_with_break
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_while_break

      const NEXT_POW -> int:
          var n: int = 1
          while true:
              n = n * 2
              if n >= 1024:
                  break
          return n

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_while_break_NEXT_POW = 1024"
  end

  def test_comptime_folds_match_expression
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_match

      const MATCHED -> int:
          return match 2:
              1: 10
              2: 20
              _: 0

      const MATCHED_STR -> str:
          return match "b":
              "a": "one"
              "b": "two"
              _: "other"

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_match_MATCHED = 20"
    assert_includes c_code, '.data = "two"'
  end

  def test_comptime_folds_index_access
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_index

      const ARR: array[int, 3] = (10, 20, 30)
      const ARR_0: int = ARR[0]

      const S: str = "hello"
      const FIRST_BYTE: ubyte = S[0]
      const SLICE: str = S[1..3]

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_index_ARR_0 = 10"
    assert_includes c_code, "comptime_index_FIRST_BYTE = 104"
    assert_includes c_code, '.data = "el"'
    refute_includes c_code, "mt_checked_index"
  end

  def test_comptime_folds_array_range_slice_in_block_body
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_slice_total

      const ARR: array[int, 3] = (10, 20, 30)

      const SLICE_TOTAL -> int:
          var total: int = 0
          for v in ARR[1..3]:
              total += v
          return total

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_slice_total_SLICE_TOTAL = 50"
  end

  def test_comptime_folds_struct_member_access
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_member

      struct Inner:
          a: int
          b: int

      struct Outer:
          name: str
          inner: Inner

      const P: Outer = Outer(name = "n", inner = Inner(a = 1, b = 2))
      const P_A: int = P.inner.a
      const P_NAME: str = P.name

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_member_P_A = 1"
    assert_includes c_code, '.data = "n"'
    refute_includes c_code, "}).inner.a"
  end

  def test_comptime_folds_member_access_on_block_local_struct
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_block_local

      struct Inner:
          a: int
          b: int

      const BLOCKED -> int:
          var total: int = 0
          for i in 0..3:
              let pt = Inner(a = i, b = i * 10)
              total += pt.b
          return total

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_block_local_BLOCKED = 30"
  end

  def test_comptime_folds_runtime_behavior
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.comptime_fold_run

      struct Inner:
          a: int
          b: int

      struct Outer:
          name: str
          inner: Inner

      const P: Outer = Outer(name = "n", inner = Inner(a = 1, b = 2))
      const P_A: int = P.inner.a
      const P_NAME: str = P.name

      const ARR: array[int, 3] = (10, 20, 30)
      const ARR_0: int = ARR[0]

      const SLICE_TOTAL -> int:
          var total: int = 0
          for v in ARR[1..3]:
              total += v
          return total

      const S: str = "hello" + "!"
      const S_BYTE: ubyte = S[0]
      const S_SLICE: str = S[1..3]

      const SUM -> int:
          var total: int = 0
          for i in 0..10:
              if i == 3:
                  continue
              if i >= 6:
                  break
              total += i
          return total

      const MATCHED -> int:
          return match 2:
              1: 10
              2: 20
              _: 0

      function main() -> int:
          if P_A != 1: return 1
          if P_NAME != "n": return 2
          if ARR_0 != 10: return 3
          if SLICE_TOTAL != 50: return 4
          if S != "hello!": return 5
          if int<-S_BYTE != 104: return 6
          if S_SLICE != "el": return 7
          if SUM != 12: return 8
          if MATCHED != 20: return 9
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end
end
