# frozen_string_literal: true

require_relative "helpers"

class ErrorDetectionTest < Minitest::Test
  include SemaTestHelpers

  def test_rejects_non_bool_conditions
    source = <<~MT
      # module demo.bad

      function main() -> int:
          if 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/if condition must be bool/, error.message)
  end

  def test_rejects_result_propagation_inside_defer_block
    source = <<~MT
      # module demo.status_defer



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function verify() -> Result[void, int]:
          defer:
              parse()?
          return Result[void, int].success(value= done())
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation is not allowed inside defer blocks/, error.message)
  end

  def test_rejects_result_propagation_when_enclosing_return_is_not_result
    source = <<~MT
      # module demo.status_non_result

      function parse(input: int) -> Result[int, int]:
          return Result[int, int].success(value= input)

      function verify(input: int) -> int:
          let value = parse(input)?
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Result\[_/, error.message)
  end

  def test_rejects_result_propagation_with_error_type_mismatch
    source = <<~MT
      # module demo.status_error_type_mismatch

      function parse(input: int) -> Result[int, long]:
          return Result[int, long].success(value= input)

      function verify(input: int) -> Result[int, int]:
          let value = parse(input)?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation error type/, error.message)
    assert_match(/must match enclosing Result error type/, error.message)
  end

  def test_rejects_result_propagation_expression_with_void_success_type
    source = <<~MT
      # module demo.status_void_success



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function verify() -> Result[int, int]:
          let value = parse()?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires a non-void Result success type/, error.message)
  end

  def test_rejects_result_propagation_on_non_result_operand
    source = <<~MT
      # module demo.status_not_result

      function verify() -> Result[int, int]:
          let value = 1?
          return Result[int, int].success(value= value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation expects Result\[T, E\] or Option\[T\]/, error.message)
  end

  def test_rejects_result_propagation_outside_function_and_proc_bodies
    source = <<~MT
      # module demo.status_top_level

      const value: int = Result[int, int].success(value= 1)?
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation is only allowed inside function and proc bodies/, error.message)
  end

  def test_rejects_option_propagation_inside_non_option_function
    source = <<~MT
      # module demo.opt_prop_bad_ret

      function find_data() -> Option[int]:
          return Option[int].some(value = 42)

      function main() -> int:
          let value = find_data()?
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Option\[_\]/, error.message)
  end

  def test_rejects_option_propagation_inside_result_function
    source = <<~MT
      # module demo.opt_in_result_fn

      enum Err: ubyte
          a = 0

      function find_data() -> Option[int]:
          return Option[int].some(value = 42)

      function main() -> Result[int, Err]:
          let value = find_data()?
          return Result[int, Err].success(value = value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Option\[_\]/, error.message)
  end

  def test_rejects_result_propagation_inside_option_function
    source = <<~MT
      # module demo.result_in_opt_fn

      enum Err: ubyte
          a = 0

      function parse(input: int) -> Result[int, Err]:
          return Result[int, Err].success(value = input)

      function main() -> Option[int]:
          let value = parse(1)?
          return Option[int].some(value = value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Result\[_/, error.message)
  end

  def test_rejects_let_else_discard_binding_with_type_annotation
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse() -> Result[void, int]:
          return Result[void, int].success(value= done())

      function main() -> int:
          let _: void = parse() else:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/let-else discard binding _ cannot have a type annotation/, error.message)
  end

  def test_rejects_var_else_discard_binding
    source = <<~MT
      # module demo.var_discard_flow



      function parse() -> Result[int, int]:
          return Result[int, int].success(value= 1)

      function main() -> int:
          var _ = parse() else:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/var-else discard binding _ is not allowed/, error.message)
  end

  def test_rejects_let_else_without_terminating_else_body
    source = <<~MT
      # module demo.null_flow

      function read_handle(handle: ptr[int]?) -> int:
          let value = handle else:
              let fallback = 0
          unsafe:
              return read(value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/else block for value must exit control flow/, error.message)
  end

  def test_accepts_let_else_continue_inside_loop
    source = <<~MT
      # module demo.loop_continue

      function first_match(values: span[ptr_uint?]) -> ptr_uint:
          var index: ptr_uint = 0
          for value in values:
              let unwrapped = value else:
                  continue
              return index
          return 0
    MT

    check_program_source(source)
  end

  def test_accepts_let_else_break_inside_loop
    source = <<~MT
      # module demo.loop_break

      function first_match(values: span[ptr_uint?]) -> ptr_uint:
          var index: ptr_uint = 0
          for value in values:
              let unwrapped = value else:
                  break
              return index
          return 0
    MT

    check_program_source(source)
  end

  def test_rejects_aio_without_explicit_async_runtime_import
    source = <<~MT
      # module demo.async_main

      async function main() -> int:
          let waited = await aio.sleep(1)
          return waited + 41
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/unknown name aio/, error.message)
  end

  def test_rejects_async_main_with_non_exit_return_type
    source = <<~MT
      # module demo.async_main

      import std.async as aio

      async function main() -> bool:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/async main must return int or void/, error.message)
  end

  def test_rejects_await_outside_async_functions
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      function parent() -> int:
          return await child()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/await is only allowed inside async functions/, error.message)
  end

  def test_rejects_await_inside_if_statement_in_async_functions
    source = <<~MT
      # module demo.async_await_in_if

      import std.async as aio

      async function child() -> int:
          return 1

      async function parent() -> int:
          if true:
              return await child()
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_rejects_await_inside_if_condition_in_async_functions
    source = <<~MT
      # module demo.async_await_in_if_cond

      import std.async as aio

      async function child() -> bool:
          return true

      async function parent() -> int:
          if await child():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_rejects_general_format_literal_with_unsupported_interpolation_type
    source = <<~MT
      # module demo.format_bad

      struct Counter:
          value: int

      function main() -> ptr_uint:
          let text = f"counter=\#{Counter(value = 1)}"
          return text.len
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/formatted string interpolation supports .* got .*Counter/, error.message)
  end

  def test_rejects_precision_spec_on_non_float
    source = <<~MT
      # module demo.fmt_spec

      function main(count: int) -> int:
          let formatted = f"count=\#{count:.2}"
          if formatted.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/precision.*float.*double|float.*double.*precision|format spec.*float.*double/i, error.message)
  end

  def test_rejects_hex_spec_on_non_integer
    source = <<~MT
      # module demo.fmt_hex_bad

      function main(pi: double) -> int:
          let text = f"pi=\#{pi:x}"
          if text.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/format spec ':x' and ':X'.*integer/i, error.message)
  end

  def test_rejects_octal_and_binary_specs_on_non_integer
    source = <<~MT
      # module demo.fmt_oct_bin_bad

      function main(pi: double) -> int:
          let octal = f"oct=\#{pi:o}"
          let binary = f"bin=\#{pi:b}"
          if octal.len == 0 or binary.len == 0:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/format spec ':o' and ':O'|format spec ':b' and ':B'/i, error.message)
  end

  def test_rejects_explicit_c_name_on_non_external_struct
    source = <<~MT
      # module demo.bad

      struct timespec = c"struct timespec":
          tv_sec: ptr_int
          tv_nsec: ptr_int
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/explicit C names are only allowed on external structs and unions/, error.message)
  end

  def test_rejects_wrong_return_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return type mismatch/, error.message)
  end

  def test_rejects_unknown_fields_in_struct_literals
    source = <<~MT
      # module demo.bad

      struct Ball:
          radius: float

      function main() -> int:
          var ball = Ball(size = 20.0)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown field Ball.size/, error.message)
  end

  def test_rejects_duplicate_top_level_values
    source = <<~MT
      # module demo.bad

      const width: int = 1
      const width: int = 2
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate value width/, error.message)
  end

  def test_rejects_function_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function double() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function double uses reserved built-in type name double/, error.message)
  end

  def test_rejects_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main(byte: int) -> int:
          return byte
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_local_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let byte = 1
          return byte
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/local byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_let_else_error_binding_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.status_bad



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function main(input: int) -> int:
          let value = parse(input) else as byte:
              return byte
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/let-else error binding byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_for_binding_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          for byte in 0..2:
              return byte
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/for binding byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_proc_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let callback = proc(byte: int) -> int:
              return byte
          return callback(1)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_rejects_type_parameter_named_after_reserved_primitive_type
    source = <<~MT
      # module demo.bad

      function identity[byte](value: byte) -> byte:
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/type parameter byte uses reserved built-in type name byte/, error.message)
  end

  def test_statement_level_sema_fallback_uses_statement_token_span
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = 1
          return value
    MT

    checker_class = MilkTea::Sema::Checker
    original = checker_class.instance_method(:check_local_decl)
    verbose = $VERBOSE
    $VERBOSE = nil
    checker_class.send(:define_method, :check_local_decl) do |_statement, scopes:, return_type:, allow_return:|
      raise MilkTea::SemaError.new("forced missing location")
    end
    checker_class.send(:private, :check_local_decl)
    $VERBOSE = verbose

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_equal 4, error.line
    assert_equal source.lines[3].index("value") + 1, error.column
    assert_equal "value".length, error.length
  ensure
    $VERBOSE = nil
    checker_class.send(:define_method, :check_local_decl, original)
    checker_class.send(:private, :check_local_decl)
    $VERBOSE = verbose
  end

  def test_rejects_stored_proc_values_with_ref_returns
    source = <<~MT
      # module demo.bad_proc_ref_storage

      struct Counter:
          value: int

      struct Entry:
          callback: proc() -> ref[Counter]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/field Entry\.callback cannot store ref types outside callable parameter positions/, error.message)
  end

  def test_rejects_foreign_defs_with_str_to_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          sample.show("demo")
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Show(text: ptr[char]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function show(text: str as ptr[char]) -> void = c.Show
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/cannot map str as ptr\[char\]/, error.message)
  end

  def test_rejects_owned_foreign_release_in_local_initializer
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              let released = win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        external function CreateWindow() -> ptr[void]?
        external function DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window

        public foreign function create() -> Window? = c.CreateWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming foreign calls must be top-level expression statements/, error.message)
  end

  def test_rejects_foreign_defs_that_drop_cstr_mutability
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main(label: cstr) -> void:
          mem.write_label(label)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function WriteLabel(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function write_label(label: cstr) -> void = c.WriteLabel
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument label to WriteLabel expects ptr\[char\], got cstr/, error.message)
  end

  def test_rejects_out_argument_outside_foreign_call
    source = <<~MT
      # module demo.bad

      function write(value: int) -> int:
          return value

      function main() -> int:
          var number = 1
          return write(out number)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/out is only allowed for foreign call arguments/, error.message)
  end

  def test_rejects_mixed_signed_and_unsigned_integer_arithmetic_without_explicit_cast
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let left: int = 1
          let right: uint = 2
          let sum = left + right
          return sum
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types/, error.message)
  end

  def test_rejects_passing_stored_str_to_cstr_parameter_without_explicit_boundary
    source = <<~MT
      # module demo.string_boundary

      external function set_text(value: cstr) -> void

      function main() -> void:
          let text: str = "hello"
          set_text(text)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to set_text expects cstr, got str/, error.message)
  end

  def test_rejects_return_inside_defer_block
    source = <<~MT
      # module demo.defer_return

      function main() -> int:
          defer:
              return 1
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return is not allowed inside defer blocks/, error.message)
  end

  def test_rejects_outer_loop_continue_inside_defer_block
    source = <<~MT
      # module demo.defer_continue

      function main() -> int:
          for outer in 0..1:
              defer:
                  continue
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_rejects_offsetof_unknown_field
    source = <<~MT
      # module demo.layout

      struct Header:
          version: ushort

      function main() -> ptr_uint:
          return offset_of(Header, missing)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown field demo\.layout\.Header\.missing/, error.message)
  end

  def test_rejects_static_assert_with_non_literal_message
    source = <<~MT
      # module demo.layout

      const MESSAGE: cstr = c"layout must hold"

      function main() -> int:
          static_assert(true, MESSAGE)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/static_assert message must be a string literal/, error.message)
  end

  def test_rejects_static_assert_with_non_constant_condition
    source = <<~MT
      # module demo.layout

      function main(count: int) -> int:
          static_assert(count > 0, "count must stay positive")
          return count
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/static_assert condition must be a compile-time bool constant/, error.message)
  end

  def test_rejects_reinterpret_of_array_types
    source = <<~MT
      # module demo.bits

      function main() -> int:
          let values = array[ubyte, 4](1, 2, 3, 4)
          unsafe:
              let bits = reinterpret[uint](values)
              return int<-bits
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/reinterpret requires non-array concrete sized types/, error.message)
  end

  def test_rejects_contextual_float_narrowing_without_float_expected_context
    source = <<~MT
      # module demo.contextual_float_expected_only

      function main() -> int:
          var angle = 1
          let radians = angle * 0.5
          let target: float = radians
          return int<-target
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign double to target: expected float/, error.message)
  end

  def test_rejects_contextual_float_narrowing_for_integer_compound_assignment_targets
    source = <<~MT
      # module demo.contextual_float_compound_reject

      function main() -> int:
          var total = 1
          total += 0.5
          return total
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+= requires matching numeric types, got int and double/, error.message)
  end

  def test_rejects_lossy_numeric_coercion_for_external_function_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_program_source(
        <<~MT,
          # module demo.external_numeric_lossy_call

          import std.c.demo as demo

          function main() -> int:
              var channel = 200
              demo.set_scale(channel)
              return 0
        MT
        {
          "std/c/demo.mt" => <<~MT,
            # module std.c.demo
            external
            external function set_scale(value: float) -> void
          MT
        },
      )
    end

    assert_match(/argument value to set_scale expects float, got int/, error.message)
  end

  def test_rejects_lossy_numeric_coercion_for_external_field_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_program_source(
        <<~MT,
          # module demo.external_numeric_lossy_field

          import std.c.demo as demo

          function main() -> int:
              var channel = 200
              var color = demo.Color(r = 0, g = 0, b = 0, a = 255)
              color.g = channel
              return 0
        MT
        {
          "std/c/demo.mt" => <<~MT,
            # module std.c.demo
            external
            struct Color:
                r: ubyte
                g: ubyte
                b: ubyte
                a: ubyte
          MT
        },
      )
    end

    assert_match(/cannot assign int to ubyte/, error.message)
  end

  def test_rejects_inexact_compile_time_numeric_coercion_for_typed_boundaries
    error = assert_raises(MilkTea::SemaError) do
      check_source(
        <<~MT,
          # module demo.inexact_numeric_constants

          function main() -> int:
              let whole: int = 2.5
              return whole
        MT
      )
    end

    assert_match(/cannot assign double to whole: expected int/, error.message)
  end

  def test_rejects_ambiguous_imported_extension_method_calls
    source = <<~MT
      # module demo.main

      import demo.dep as dep
      import demo.a as a
      import demo.b as b

      function main(value: dep.Counter) -> int:
          value.tag()
          return 0
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/a.mt" => <<~MT,
        # module demo.a

        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 1
      MT
      "demo/b.mt" => <<~MT,
        # module demo.b

        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 2
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/ambiguous imported method demo\.dep\.Counter\.tag; found in modules demo\.a, demo\.b/, error.message)
    assert_equal 8, error.line
    assert_equal 11, error.column
  end

  def test_rejects_ambiguous_imported_extension_associated_function_calls
    source = <<~MT
      # module demo.main

      import demo.dep as dep
      import demo.a as a
      import demo.b as b

      function main() -> int:
          dep.Counter.zero()
          return 0
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public struct Counter:
            value: int
      MT
      "demo/a.mt" => <<~MT,
        # module demo.a

        import demo.dep as dep

        extending dep.Counter:
            public static function zero() -> dep.Counter:
                return dep.Counter(value = 1)
      MT
      "demo/b.mt" => <<~MT,
        # module demo.b

        import demo.dep as dep

        extending dep.Counter:
            public static function zero() -> dep.Counter:
                return dep.Counter(value = 2)
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/ambiguous imported method demo\.dep\.Counter\.zero; found in modules demo\.a, demo\.b/, error.message)
    assert_equal 8, error.line
    assert_equal 17, error.column
  end

  def test_rejects_same_width_enum_and_flags_arguments_without_explicit_cast_for_non_extern_calls
    source = <<~MT
      # module demo.call_values

      flags Gesture: int
          tap = 1

      function takes_uint(value: uint) -> int:
          return 0

      function main() -> int:
          takes_uint(Gesture.tap)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to takes_uint expects uint, got .*Gesture/, error.message)
  end

  def test_rejects_variadic_extern_calls_missing_required_arguments
    source = <<~MT
      # module demo.printf

      external function printf(format: cstr, ...) -> int

      function main() -> int:
          return printf()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function printf expects at least 1 arguments, got 0/, error.message)
  end

  def test_rejects_same_width_enum_and_flags_assignment_without_explicit_cast
    source = <<~MT
      # module demo.bad

      flags Gesture: int
          tap = 1

      function main() -> int:
          let gesture: uint = Gesture.tap
          return int<-gesture
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign .*Gesture to gesture: expected uint/, error.message)
  end

  def test_rejects_non_power_of_two_alignment
    source = <<~MT
      # module demo.layout

      @[align(3)]
      struct Mat4:
          data: array[float, 16]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/align\(\.\.\.\) requires a power-of-two alignment, got 3/, error.message)
  end

  def test_rejects_attribute_on_wrong_target
    source = <<~MT
      # module demo.bad

      public attribute[field] rename(name: str)

      @[rename("packet")]
      struct Packet:
          value: uint
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/attribute rename cannot target struct/, error.message)
  end

  def test_rejects_break_and_continue_outside_loops
    break_source = <<~MT
      # module demo.bad

      function main() -> int:
          break
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(break_source)
    end
    assert_match(/break must be inside a loop/, error.message)

    continue_source = <<~MT
      # module demo.bad

      function main() -> int:
          continue
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(continue_source)
    end
    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_rejects_for_loop_over_non_iterable_value
    source = <<~MT
      # module demo.for_loops

      function main() -> int:
          for value in 3:
              let copy = value
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/for loop expects start\.\.stop, array\[T, N\], span\[T\], or an iterable with iter\(\)\/next\(\)/, error.message)
  end

  def test_rejects_dot_dot_range_with_non_integer_bounds
    source = <<~MT
      # module demo.for_loops

      function main() -> void:
          for i in 0.0..1.0:
              let x = i
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/range bounds must be integer types/, error.message)
  end

  def test_rejects_dot_dot_range_with_mismatched_bound_types
    source = <<~MT
      # module demo.for_loops

      function main(n: ptr_uint) -> void:
          for i in 0..n:
              let x: ptr_uint = i
    MT

    # This should succeed: literal 0 adapts to ptr_uint
    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_range_index_assignment_with_non_literal_bounds
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float], n: ptr_uint) -> void:
          unsafe:
              buf[0..n] = (1.0, 2.0, 3.0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires integer literal bounds/, error.message)
  end

  def test_rejects_range_index_assignment_with_mismatched_count
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float]) -> void:
          unsafe:
              buf[0..3] = (1.0, 2.0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/spans 3 elements but tuple has 2/, error.message)
  end

  def test_rejects_non_exhaustive_match_statement_over_enum
    source = <<~MT
      # module demo.match

      enum EventKind: ubyte
          quit = 1
          resize = 2

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
          return 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/match on demo.match.EventKind is missing cases: resize/, error.message)
  end

  def test_rejects_fatal_with_non_string_message
    source = <<~MT
      # module demo.fatal

      function main() -> int:
          fatal(123)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/fatal expects str or cstr, got int/, error.message)
  end

  def test_rejects_mismatched_callback_arguments
    source = <<~MT
      # module demo.callbacks

      type LogCallback = fn(level: int, message: cstr) -> void
      external function set_callback(callback: LogCallback) -> void

      function wrong(level: int) -> void:
          return

      function main() -> int:
          set_callback(wrong)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument callback to set_callback expects/, error.message)
  end

  def test_rejects_partial_array_construction_with_too_many_elements
    source = <<~MT
      # module demo.too_many_array_elements

      function main() -> int:
          let values = array[int, 2](1, 2, 3)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array expects at most 2 elements, got 3/, error.message)
  end

  def test_rejects_zero_for_void
    source = <<~MT
      # module demo.zero_bad

      function main() -> int:
          let value = zero[void]
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/zero does not support type void/, error.message)
  end

  def test_rejects_default_specialization_without_explicit_associated_default
    source = <<~MT
      # module demo.default_builtin_bad

      struct Plain:
          hp: int

      function make_default[T]() -> T:
          return default[T]

      function main() -> int:
          let plain = make_default[Plain]()
          return plain.hp
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/default\[demo\.default_builtin_bad\.Plain\] requires associated function demo\.default_builtin_bad\.Plain\.default\(\)/, error.message)
  end

  def test_rejects_default_call_form
    source = <<~MT
      # module demo.default_call_form

      function main() -> int:
          let value = default[int]()
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown name default/, error.message)
  end

  def test_rejects_zero_call_form
    source = <<~MT
      # module demo.zero_call_form

      function main() -> int:
          let value = zero[int]()
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown name zero/, error.message)
  end

  def test_rejects_cast_call_form
    source = <<~MT
      # module demo.cast_call_form

      function main(value: int) -> long:
          return cast[long](value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown name cast/, error.message)
  end

  def test_rejects_default_override_with_parameters
    source = <<~MT
      # module demo.bad_default_override

      struct Player:
          hp: int

      extending Player:
          static function default(seed: int) -> Player:
              return Player(hp = seed)

      function main() -> int:
          let player = default[Player]
          return player.hp
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/default\[demo\.bad_default_override\.Player\] requires demo\.bad_default_override\.Player\.default\(\) to take 0 arguments/, error.message)
  end

  def test_rejects_extern_array_params_and_returns
    param_source = <<~MT
      # module demo.bad_params

      external function take(values: array[int, 4]) -> int
    MT

    param_error = assert_raises(MilkTea::SemaError) do
      check_source(param_source)
    end

    assert_match(/external function take cannot take array parameters/, param_error.message)

    return_source = <<~MT
      # module demo.bad_return

      external function make() -> array[int, 4]
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/external function make cannot return arrays/, return_error.message)
  end

  def test_rejects_external_function_with_proc_parameter
    source = <<~MT
      # module demo.external_proc_param

      external function install(callback: proc() -> void) -> void
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/external function install cannot take proc parameters/, error.message)
  end

  def test_rejects_mut_method_call_on_read_only_raw_pointer
    source = <<~MT
      # module demo.bad

      struct Counter:
          value: int

      extending Counter:
          editable function add(delta: int):
              this.value += delta

      function main() -> int:
          var counter = Counter(value = 3)
          let counter_ptr = const_ptr_of(counter)
          unsafe:
              counter_ptr.add(1)
          return counter.value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot call editable method add on an immutable receiver/, error.message)
  end

  def test_rejects_safe_indexing_of_temporary_array_values
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = array[int, 4](1, 2, 3, 4)[0]
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/safe array indexing requires an addressable array value/, error.message)
  end

  def test_rejects_dereference_of_non_pointer
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = read(1)
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/read expects ref\[\.\.\.\] or ptr\[\.\.\.\], got int/, error.message)
  end

  def test_reports_invalid_prefix_cast_at_cast_expression_column
    source = <<~MT
      function main() -> int:
          return unsafe: read(ptr[int]<-0)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cast currently only supports numeric primitive types/, error.message)
    assert_equal 2, error.line
    assert_equal 25, error.column
  end

  def test_rejects_foreign_in_argument_with_legacy_marker
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(in value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument value to inspect must not use in/, error.message)
  end

  def test_rejects_foreign_in_parameter_without_const_ptr_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as ptr[void]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/in parameter value of inspect must lower to const_ptr\[\.\.\.\]/, error.message)
  end

  def test_rejects_incompatible_foreign_in_parameter_mapping
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Inspect(value: const_ptr[float]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect(in value: int as const_ptr[float]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/in parameter value of inspect cannot map int as const_ptr\[float\]/, error.message)
  end

  def test_rejects_consuming_foreign_parameter_with_non_pointer_public_type
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          sample.release(1)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Release(value: int) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function release(consuming value: int) -> void = c.Release
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming parameter value of release must use a non-null opaque or ptr\[\.\.\.\] type/, error.message)
  end

  def test_rejects_const_pointer_for_writable_pointer_parameters
    source = <<~MT
      # module demo.bad_const_pointer

      external function write(values: ptr[int]) -> void

      function main() -> void:
          let value = 7
          write(const_ptr_of(value))
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/expects ptr\[int\], got const_ptr\[int\]/, error.message)
  end

  def test_rejects_array_as_span_on_ordinary_call_with_temporary_source
    source = <<~MT
      # module demo.array_span_temporary

      function consume(items: span[int]) -> ptr_uint:
          return items.len

      function main() -> int:
          let used = consume(zero[array[int, 3]])
          return int<-used
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/expects span\[int\], got array\[int, 3\]/, error.message)
  end

  def test_rejects_implicit_array_to_span_in_local_binding
    source = <<~MT
      # module demo.array_span_binding

      function main() -> ptr_uint:
          var values = zero[array[int, 3]]
          let view: span[int] = values
          return view.len
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign array\[int, 3\] to view: expected span\[int\]/, error.message)
  end

  def test_rejects_typed_local_without_initializer_for_non_zero_initializable_type
    source = <<~MT
      # module demo.bad_local

      function main() -> void:
          let callback: fn(value: int) -> void
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/without initializer requires a zero-initializable type/, error.message)
  end

  def test_rejects_array_char_text_methods
    source = <<~MT
      # module demo.char_array_methods

      function main() -> int:
          var buffer = zero[array[char, 16]]
          let view = buffer.as_str()
          let label = buffer.as_cstr()
          return int<-view.len
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 16\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_removed_predecessor_of_str_buffer_type
    removed_type_name = %w[str builder].join("_")

    source = <<~MT
      # module demo.main

      function main() -> void:
          var buffer: #{removed_type_name}[8]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type #{Regexp.escape(removed_type_name)}/, error.message)
  end

  def test_rejects_removed_cstr_list_buffer_type
    source = <<~MT
      # module demo.main

      function main() -> void:
          var labels: cstr_list_buffer[3, 64]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type cstr_list_buffer/, error.message)
  end

  def test_rejects_array_char_as_str_on_temporary_receiver
    source = <<~MT
      # module demo.char_array_bad_view

      function main() -> str:
          return zero[array[char, 8]].as_str()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_array_char_as_cstr_on_temporary_receiver
    source = <<~MT
      # module demo.char_array_bad_cstr

      function main() -> cstr:
          return zero[array[char, 8]].as_cstr()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_foreign_str_as_cstr_calls_with_array_char_as_cstr
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: array[char, 32]
          ui.label(buffer.as_cstr())
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external

        external function Label(text: cstr) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function label(text: str as cstr) -> void = c.Label
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/array\[char, 32\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_char_as_general_numeric_type
    source = <<~MT
      # module demo.bad_char_numeric

      function main() -> int:
          let value = char<-65
          return value + 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types, got char and int/, error.message)
  end

  def test_rejects_ref_of_immutable_values
    source = <<~MT
      # module demo.bad

      function main() -> int:
          let value = 1
          let handle = ref_of(value)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign to immutable value/, error.message)
  end

  def test_rejects_ref_storage_and_escape_types
    field_source = <<~MT
      # module demo.bad_field

      struct Holder:
          value: ref[int]
    MT

    field_error = assert_raises(MilkTea::SemaError) do
      check_source(field_source)
    end

    assert_match(/field Holder\.value cannot store ref types/, field_error.message)

    extern_source = <<~MT
      # module demo.bad_param

      external function take(value: ref[int]) -> void
    MT

    extern_error = assert_raises(MilkTea::SemaError) do
      check_source(extern_source)
    end

    assert_match(/external function take cannot take ref parameters/, extern_error.message)

    return_source = <<~MT
      # module demo.bad_return

      function leak(value: ref[int]) -> ref[int]:
          return value
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/function leak cannot return ref types/, return_error.message)
  end

  def test_allows_stored_function_values_with_ref_parameters
    source = <<~MT
      # module demo.ref_callback_storage

      struct Counter:
          value: int

      struct Entry:
          callback: fn(arg0: ref[Counter]) -> bool

      function increment(counter: ref[Counter]) -> bool:
          counter.value += 1
          return true

      function main() -> int:
          var counter = Counter(value = 0)
          let entry = Entry(callback = increment)
          let callbacks = array[fn(arg0: ref[Counter]) -> bool, 1](entry.callback)
          if not callbacks[0](ref_of(counter)):
              return 1
          return counter.value
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_stored_function_values_with_ref_returns
    source = <<~MT
      # module demo.bad_ref_callback_storage

      struct Counter:
          value: int

      struct Entry:
          callback: fn() -> ref[Counter]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/field Entry\.callback cannot store ref types outside callable parameter positions/, error.message)
  end

  def test_rejects_non_integer_flags_backing_types
    source = <<~MT
      # module demo.bad

      flags BadFlags: float
          visible = 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/backing type must be an integer primitive/, error.message)
  end

  def test_rejects_non_constant_flags_members
    source = <<~MT
      # module demo.bad

      import demo.dep as dep

      flags BadFlags: uint
          visible = dep.next_flag
    MT

    imported = {
      "demo/dep.mt" => <<~MT,
        # module demo.dep

        public var next_flag: uint = 1
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/member BadFlags\.visible must be a compile-time integer constant/, error.message)
  end

  def test_rejects_unknown_enum_members
    source = <<~MT
      # module demo.bad

      enum State: ubyte
          idle = 0

      function main() -> int:
          let state: State = State.moving
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown member .*State\.moving/, error.message)
  end

  def test_rejects_foreign_external_struct_boundary_with_different_layout
    source = <<~MT
      # module demo.main

      import std.shared as shared
      import std.sample as sample

      function main() -> void:
          sample.set_matrix(shared.IDENTITY)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        # module std.c.shared
        external
        struct Matrix:
            m0: float
      MT
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Matrix:
            m0: float
            m1: float

        external function SetMatrix(matrix: Matrix) -> void
      MT
      "std/shared.mt" => <<~MT,
        # module std.shared

        import std.c.shared as c

        public type Matrix = c.Matrix
        public const IDENTITY: Matrix = Matrix(m0 = 1.0)
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c
        import std.shared as shared

        public foreign function set_matrix(matrix: shared.Matrix as c.Matrix) -> void = c.SetMatrix
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported_sources)
    end

      def test_allows_callback_parameters_with_ref_arguments
        source = <<~MT
          # module demo.ref_callback_param

          struct Counter:
              value: int

          function each(counter: ref[Counter], body: fn(arg0: ref[Counter]) -> bool) -> bool:
              return body(counter)

          function increment(counter: ref[Counter]) -> bool:
              counter.value += 1
              return true

          function main() -> int:
              var counter = Counter(value = 0)
              if not each(ref_of(counter), increment):
                  return 1
              return counter.value
        MT

        result = check_source(source)

        assert_equal "fn(arg0: ref[demo.ref_callback_param.Counter]) -> bool", result.functions.fetch("each").type.params[1].type.to_s
      end

    assert_match(/foreign parameter matrix of set_matrix cannot map std\.c\.shared\.Matrix as std\.c\.sample\.Matrix/, error.message)
  end

  def test_rejects_integer_match_missing_wildcard
    source = <<~MT
      # module demo.int_match_bad

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              27:
                  return 2

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires a wildcard arm/, error.message)
  end

  def test_rejects_non_literal_pattern_in_integer_match
    source = <<~MT
      # module demo.int_match_bad_pattern

      var x: int = 65

      function dispatch(key: int) -> int:
          match key:
              x:
                  return 1
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/must be an integer literal or _/, error.message)
  end

  def test_rejects_duplicate_wildcard_in_match
    source = <<~MT
      # module demo.dup_wild

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              _:
                  return 0
              _:
                  return 99

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate wildcard arm/, error.message)
  end

  def test_rejects_duplicate_integer_match_arm_value
    source = <<~MT
      # module demo.dup_int

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              65:
                  return 2
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate match arm value/, error.message)
  end

  def test_rejects_non_exhaustive_variant_match
    source = <<~MT
      # module demo.variant_non_exhaustive

      variant Shape:
          circle(radius: double)
          rect(w: double, h: double)
          point

      function area(s: Shape) -> double:
          match s:
              Shape.circle as c:
                  return c.radius
              Shape.rect as r:
                  return r.w
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
  end

  def test_rejects_variant_construction_with_missing_fields
    source = <<~MT
      # module demo.variant_fields

      variant Shape:
          circle(radius: double)

      function main() -> int:
          let c: Shape = Shape.circle()
          return 0
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
  end

  def test_rejects_as_binding_on_no_payload_arm
    source = <<~MT
      # module demo.variant_no_payload

      variant Shape:
          point

      function main() -> int:
          let s: Shape = Shape.point
          match s:
              Shape.point as p:
                  return 0
    MT

    assert_raises(MilkTea::SemaError) { check_source(source) }
  end

  def test_rejects_while_loop_with_non_bool_condition
    source = <<~MT
      # module demo.bad_while

      function main() -> int:
          while 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/while condition must be bool/, error.message)
  end

  def test_rejects_event_storage_parameter_by_value
    source = <<~MT
      # module demo.event_param

      struct Window:
          public event closed[4]

      function bad(window: Window) -> void:
          return
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/must pass event storage through ref\[\.\.\.\] or pointers/, error.message)
  end

  def test_rejects_get_on_non_array_non_span
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            let x = 42
            let p = get(x, 0) else:
                return 1
            return 0
      MT
    end

    assert_match(/get expects an array or span/, error.message)
  end

  def test_rejects_get_with_non_integer_index
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            var arr = array[int, 2](1, 2)
            let p = get(arr, true) else:
                return 1
            return 0
      MT
    end

    assert_match(/get index must be an integer type/, error.message)
  end

  def test_rejects_get_with_named_arguments
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            var arr = array[int, 2](1, 2)
            let p = get(array = arr, index = 0) else:
                return 1
            return 0
      MT
    end

    assert_match(/get does not support named arguments/, error.message)
  end

  def test_rejects_get_with_wrong_argument_count
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            var arr = array[int, 2](1, 2)
            let p = get(arr, 0, 1) else:
                return 1
            return 0
      MT
    end

    assert_match(/get expects 2 arguments/, error.message)
  end

  def test_rejects_get_on_temporary_array_value
    error = assert_raises(MilkTea::SemaError) do
      check_source(<<~MT)
        function main() -> int:
            let p = get(array[int, 3](1, 2, 3), 0) else:
                return 1
            return 0
      MT
    end

    assert_match(/get requires an addressable array value/, error.message)
  end

  # ── Inline compile-time statement errors ───────────────────────────────────

  def test_rejects_inline_if_with_runtime_condition
    source = <<~MT
      # module demo.main

      function main(flag: bool) -> int:
          inline if flag:
              return 1
          else:
              return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/inline if condition must be a compile-time constant/, error.message)
  end

  def test_rejects_inline_if_with_non_bool_const
    source = <<~MT
      # module demo.main

      const X: int = 42

      function main() -> int:
          inline if X:
              return 1
          else:
              return 0
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/inline if condition must be bool/, error.message)
  end

  def test_rejects_inline_while_with_runtime_condition
    source = <<~MT
      # module demo.main

      function main(limit: int) -> int:
          var n: int = 1
          inline while n < limit:
              n = n * 2
          return n
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/must be a compile-time constant/, error.message)
  end

  def test_rejects_inline_for_with_runtime_iterable
    source = <<~MT
      # module demo.main

      function main(items: span[int]) -> void:
          inline for item in items:
              return
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/inline for iterable must be a compile-time constant/, error.message)
  end

  def test_rejects_when_with_runtime_discriminant
    source = <<~MT
      # module demo.main

      function main(os: int) -> int:
          when os:
              1:
                  return 1
              2:
                  return 2
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/compile-time constant/, error.message)
  end

  def test_rejects_struct_with_unknown_field
    source = <<~MT
      # module demo.with_bad_field

      struct Point:
          x: float
          y: float

      function bad(p: Point) -> Point:
          return p.with(bad = 5.0)
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/unknown field/, error.message)
  end

  def test_rejects_struct_with_positional_argument
    source = <<~MT
      # module demo.with_pos

      struct Point:
          x: float
          y: float

      function bad(p: Point) -> Point:
          return p.with(5.0)
    MT

    error = assert_raises(MilkTea::SemaError) { check_source(source) }
    assert_match(/requires named arguments/, error.message)
  end

end
