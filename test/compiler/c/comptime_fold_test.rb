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

  def test_comptime_folds_char_literal_values
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_char

      const CHAR_ADD -> int:
          return 'A' + 0

      const CHAR_ESC: ubyte = '\\n'

      const CHAR_MATCH -> int:
          return match 'b':
              'a': 1
              'b': 2
              _: 0

      const CHAR_CMP -> bool:
          return 'A' == 'A' and 'B' != 'A'

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_char_CHAR_ADD = 65"
    assert_includes c_code, "comptime_char_CHAR_ESC = 10"
    assert_includes c_code, "comptime_char_CHAR_MATCH = 2"
    assert_includes c_code, "comptime_char_CHAR_CMP = true"
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

  def test_comptime_folds_static_const_method
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_const_method_static

      struct Rect:
          w: int
          h: int

      extending Rect:
          static const function make(w: int, h: int) -> Rect:
              return Rect(w = w, h = h)

      const R: Rect = Rect.make(10, 20)
      const AREA: int = R.w * R.h

      function main() -> int:
          return 0
    MT

    assert_includes c_code, ".w = 10, .h = 20"
  end

  def test_comptime_folds_plain_const_method_with_receiver
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_const_method_plain

      struct Rect:
          w: int
          h: int

          const function area() -> int:
              return this.w * this.h

      const R: Rect = Rect(w = 10, h = 20)
      const AREA: int = R.area()

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_const_method_plain_AREA = 200"
  end

  def test_comptime_folds_const_method_this_dispatch
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_const_method_this

      struct Rect:
          w: int
          h: int

          const function area() -> int:
              return this.w * this.h

          const function double_area() -> int:
              return this.area() * 2

      const R: Rect = Rect(w = 10, h = 20)
      const DOUBLE: int = R.double_area()

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_const_method_this_DOUBLE = 400"
  end

  def test_comptime_folds_const_method_on_block_local
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_const_method_local

      struct Rect:
          w: int
          h: int

          const function area() -> int:
              return this.w * this.h

      extending Rect:
          static const function make(w: int, h: int) -> Rect:
              return Rect(w = w, h = h)

      const COMBINED -> int:
          let r = Rect.make(3, 4)
          return r.area() + r.area()

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_const_method_local_COMBINED = 24"
  end

  def test_comptime_folds_const_method_in_inline_conditions
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_const_method_inline

      struct Rect:
          w: int
          h: int

          const function area() -> int:
              return this.w * this.h

      extending Rect:
          static const function make(w: int, h: int) -> Rect:
              return Rect(w = w, h = h)

      const R: Rect = Rect.make(10, 20)

      function when_demo() -> int:
          when R.area():
              200:
                  return 1
              else:
                  return 0

      function inline_if_demo() -> int:
          inline if Rect.make(2, 5).area() == 10:
              return 1
          return 0

      function main() -> int:
          return 0
    MT

    assert_includes c_code, ".w = 10, .h = 20"
  end

  def test_const_method_rejects_editable_and_interface
    source = <<~MT
      # module demo.comptime_const_method_bad

      struct S:
          a: int
          editable const function bad() -> void:
              pass

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) { check_program_source(source) }
    assert_match(/editable methods cannot be const/, error.message)

    interface_source = <<~MT
      # module demo.comptime_const_method_interface_bad

      interface I:
          const function bad() -> void

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::ParseError) { check_program_source(interface_source) }
    assert_match(/const is not allowed on interface methods/, error.message)
  end

  def test_comptime_folds_const_method_runtime_behavior
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.comptime_const_method_run

      struct Rect:
          w: int
          h: int

          const function area() -> int:
              return this.w * this.h

      extending Rect:
          static const function make(w: int, h: int) -> Rect:
              return Rect(w = w, h = h)

          const function helpers() -> void:
              emit function from_method() -> int:
                  return 7

      const R: Rect = Rect.make(10, 20)
      const AREA_FOLDED: int = R.area()

      function main() -> int:
          if R.area() != 200: return 1
          if AREA_FOLDED != 200: return 2
          let local = Rect.make(5, 6)
          if local.area() != 30: return 3
          if Rect.make(2, 3).area() != 6: return 4
          if from_method() != 7: return 5
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_comptime_folds_numeric_prefix_casts
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_precast

      const F1: int = int<-3.7
      const F2: ubyte = ubyte<-300
      const F3: byte = byte<-(-300)
      const F4: int = int<-true
      const F5: uint = uint<-(-1)
      const F6: short = short<-70000
      const F7: float = float<-7

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_precast_F1 = 3"
    assert_includes c_code, "comptime_precast_F2 = 44"
    assert_includes c_code, "comptime_precast_F3 = -44"
    assert_includes c_code, "comptime_precast_F4 = 1"
    assert_includes c_code, "comptime_precast_F5 = 4294967295"
    assert_includes c_code, "comptime_precast_F6 = 4464"
    assert_includes c_code, "comptime_precast_F7 = 7.0f"
  end

  def test_comptime_folds_const_block_field_and_index_assignment
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_assign

      struct Pt:
          x: int
          y: int

      const D -> int:
          var p = Pt(x = 1, y = 2)
          p.y = 5
          return p.y

      const DA -> int:
          var arr = array[int, 3](1, 2, 3)
          arr[1] = 9
          arr[2] += 1
          return arr[1] + arr[2]

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_assign_D = 5"
    assert_includes c_code, "comptime_assign_DA = 13"
  end

  def test_comptime_folds_const_block_destructuring
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_destructure

      struct Pt:
          x: int
          y: int

      const E -> int:
          let (a, b) = (10, 20)
          let Pt(cx, cy) = Pt(x = 3, y = 4)
          return a + b + cx + cy

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_destructure_E = 37"
  end

  def test_comptime_folds_runtime_behavior_for_casts_assignments_destructure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.comptime_bde_run

      struct Pt:
          x: int
          y: int

      const F1: int = int<-3.7
      const F2: ubyte = ubyte<-300
      const F3: int = int<-true

      const D -> int:
          var p = Pt(x = 1, y = 2)
          p.y = 5
          return p.y

      const E -> int:
          let (a, b) = (10, 20)
          let Pt(cx, cy) = Pt(x = 3, y = 4)
          return a + b + cx + cy

      const COW -> int:
          var a = Pt(x = 1, y = 2)
          var b = a
          a.x = 5
          return b.x

      function main() -> int:
          if int<-3.7 != F1: return 1
          if ubyte<-300 != F2: return 2
          if int<-true != F3: return 3
          if D != 5: return 4
          if E != 37: return 5
          if COW != 1: return 6
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_comptime_folds_const_block_guards
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_guard

      const OPT_SOME -> int:
          let x = Option[int].some(value = 42) else:
              return 9
          return x

      const OPT_NONE -> int:
          let x = Option[int].none else:
              return 9
          return x

      const RESULT_OK -> int:
          let x = Result[int, str].success(value = 7) else as error:
              return 0
          return x

      const RESULT_ERR -> int:
          let x = Result[int, str].failure(error = "bad") else as error:
              if error == "bad":
                  return 44
              return 0
          return x

      const DISCARD -> int:
          let _ = Result[int, int].success(value = 1) else:
              return 0
          return 55

      const NULLABLE_PRESENT -> int:
          let maybe: int? = 42
          let x = maybe else:
              return 9
          return x

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_guard_OPT_SOME = 42"
    assert_includes c_code, "comptime_guard_OPT_NONE = 9"
    assert_includes c_code, "comptime_guard_RESULT_OK = 7"
    assert_includes c_code, "comptime_guard_RESULT_ERR = 44"
    assert_includes c_code, "comptime_guard_DISCARD = 55"
    assert_includes c_code, "comptime_guard_NULLABLE_PRESENT = 42"
  end

  def test_comptime_folds_guard_in_const_method
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_guard_method

      struct Wrapper:
          v: int

      extending Wrapper:
          const function guarded() -> int:
              let x = Option[int].some(value = 100) else:
                  return 0
              return x + this.v

      const W: Wrapper = Wrapper(v = 5)
      const W_GUARDED: int = W.guarded()

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_guard_method_W_GUARDED = 105"
  end

  def test_comptime_folds_runtime_behavior_for_guards
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~'MT'
      # module demo.comptime_guard_run

      const F_SOME -> int:
          let x = Option[int].some(value = 42) else:
              return 9
          return x

      const F_NONE -> int:
          let x = Option[int].none else:
              return 9
          return x

      const F_ERR -> int:
          let x = Result[int, str].failure(error = "bad") else as error:
              if error == "bad":
                  return 44
              return 0
          return x

      const F_NULL -> int:
          let maybe: int? = 42
          let x = maybe else:
              return 9
          return x

      function r_some() -> int:
          let x = Option[int].some(value = 42) else:
              return 9
          return x

      function r_none() -> int:
          let x = Option[int].none else:
              return 9
          return x

      function r_err() -> int:
          let x = Result[int, str].failure(error = "bad") else as error:
              if error == "bad":
                  return 44
              return 0
          return x

      function r_null() -> int:
          let maybe: int? = 42
          let x = maybe else:
              return 9
          return x

      function main() -> int:
          if F_SOME != r_some(): return 1
          if F_NONE != r_none(): return 2
          if F_ERR != r_err(): return 3
          if F_NULL != r_null(): return 4
          return 0
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_comptime_folds_qualified_struct_constructor
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_qualified_ctor

      struct Outer:
          struct Inner:
              v: int

      const NESTED_CTOR -> int:
          let i = Outer.Inner(v = 7)
          return i.v

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_qualified_ctor_NESTED_CTOR = 7"
  end

  def test_comptime_folds_type_receiver_const_method_with_block_local_args
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_type_receiver_local

      struct Rect:
          w: int

      extending Rect:
          static const function scaled(factor: int) -> int:
              return factor * 2

      const TYPE_RECEIVER_LOCAL -> int:
          let local = 5
          return Rect.scaled(local)

      function main() -> int:
          return 0
    MT

    assert_includes c_code, "comptime_type_receiver_local_TYPE_RECEIVER_LOCAL = 10"
  end

  def test_comptime_folds_hex_string_parser
    c_code = generate_c_from_program_source(<<~MT)
      # module demo.comptime_hex

      struct Rgb:
          r: ubyte
          g: ubyte
          b: ubyte
          a: ubyte

      extending Rgb:
          static const function hex_digit(c: ubyte) -> ubyte:
              if c >= '0' and c <= '9':
                  return c - '0'
              if c >= 'a' and c <= 'f':
                  return c - 'a' + 10
              return c - 'A' + 10

          static const function from_hex_str(color: str) -> Rgb:
              return Rgb(
                  r = Rgb.hex_digit(color[1]) * 16 + Rgb.hex_digit(color[2]),
                  g = Rgb.hex_digit(color[3]) * 16 + Rgb.hex_digit(color[4]),
                  b = Rgb.hex_digit(color[5]) * 16 + Rgb.hex_digit(color[6]),
                  a = 255,
              )

      const MIDNIGHT: Rgb = Rgb.from_hex_str("#10121c")

      function main() -> int:
          return 0
    MT

    assert_includes c_code, ".r = 16, .g = 18, .b = 28, .a = 255"
  end
end
