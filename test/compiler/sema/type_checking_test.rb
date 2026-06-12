# frozen_string_literal: true

require_relative "helpers"

class TypeCheckingTest < Minitest::Test
  include SemaTestHelpers

  def test_type_checks_let_else_status_success_binding
    source = <<~MT
      # module demo.status_flow



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else:
              return 7
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_maybe_success_binding
    source = <<~MT
      # module demo.maybe_flow



      function parse(input: int) -> Option[int]:
          if input < 0:
              return Option[int].none
          return Option[int].some(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else:
              return 7
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_status_error_binding
    source = <<~MT
      # module demo.status_flow



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function read_value(input: int) -> int:
          let value = parse(input) else as error:
              return error
          return value + 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_let_else_status_void_discard_binding
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function read_value(input: int) -> int:
          let _ = parse(input) else as error:
              return error
          return 10
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_result_void_propagation_statement
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function verify(input: int) -> Result[void, int]:
          parse(input)?
          return Result[void, int].success(value= done())
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_propagation_inside_async_function
    source = <<~MT
      # module demo.status_void_flow



      function parse(input: int) -> Result[int, int]:
          return Result[int, int].success(value= input + 1)

      async function verify(input: int) -> Result[str, int]:
          let value = parse(input)?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_propagation_over_await_inside_async_function
    source = <<~MT
      # module demo.status_void_flow

      import std.async as aio


      async function parse(input: int) -> Result[int, int]:
          await aio.sleep(1)
          return Result[int, int].success(value= input + 1)

      async function verify(input: int) -> Result[str, int]:
          let value = (await parse(input))?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_result_void_propagation_statement_inside_async_function
    source = <<~MT
      # module demo.status_void_flow



      function done() -> void:
          return

      function parse(input: int) -> Result[void, int]:
          if input < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      async function verify(input: int) -> Result[void, int]:
          parse(input)?
          return Result[void, int].success(value= done())
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("verify")
  end

  def test_type_checks_var_else_status_success_binding_and_assignment
    source = <<~MT
      # module demo.var_status_flow



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function read_value(input: int) -> int:
          var value = parse(input) else:
              return 7
          value += 3
          return value
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("read_value")
  end

  def test_type_checks_option_propagation_expression
    source = <<~MT
      # module demo.opt_propagation

      function find_data() -> Option[int]:
          return Option[int].some(value = 42)

      function lookup(key: str) -> Option[int]:
          let value = find_data()?
          return Option[int].some(value = value + 1)
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("lookup")
  end

  def test_type_checks_option_propagation_diff_types
    source = <<~MT
      # module demo.opt_prop_diff

      function find_str() -> Option[str]:
          return Option[str].some(value = "hello")

      function count_chars(key: str) -> Option[int]:
          let s = find_str()?
          return Option[int].some(value = 42)
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("count_chars")
  end

  def test_type_checks_option_void_propagation_statement
    source = <<~MT
      # module demo.opt_void_stmt

      function maybe_fail() -> Option[int]:
          return Option[int].some(value = 42)

      function process() -> Option[str]:
          maybe_fail()?
          return Option[str].some(value = "ok")
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("process")
  end

  def test_type_checks_for_loop_over_custom_iterator_protocol
    source = <<~MT
      # module demo.iterator_for

      struct Numbers:
          stop: int

      struct NumbersIter:
          index: int
          stop: int
          current: int

      extending Numbers:
          public function iter() -> NumbersIter:
              return NumbersIter(index = 0, stop = this.stop, current = 0)

      extending NumbersIter:
          public editable function next() -> ptr[int]?:
              if this.index >= this.stop:
                  return null[ptr[int]]
              this.current = this.index
              this.index += 1
              unsafe:
                  return ptr_of(this.current)

      function main() -> int:
          var total = 0
          for value in Numbers(stop = 3):
              unsafe:
                  total += read(value)
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_for_loop_over_bool_current_iterator_protocol
    source = <<~MT
      # module demo.iterator_current

      struct Numbers:
          stop: int

      struct NumbersIter:
          index: int
          stop: int

      extending Numbers:
          public function iter() -> NumbersIter:
              return NumbersIter(index = 0, stop = this.stop)

      extending NumbersIter:
          public editable function next() -> bool:
              if this.index >= this.stop:
                  return false
              this.index += 1
              return true

          public function current() -> int:
              return this.index - 1

      function main() -> int:
          var total = 0
          for value in Numbers(stop = 3):
              total += value
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_struct_span_for_loop_as_mutable_alias
    source = <<~MT
      # module demo.for_ref

      struct Position:
          x: int
          y: int

      function apply(items: span[Position]) -> void:
          for item in items:
              item.x += 1
              item.y += 2
          return
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
  end

  def test_type_checks_parallel_collection_for_loop
    source = <<~MT
      # module demo.parallel_for

      struct Position:
          x: int
          y: int

      struct Velocity:
          x: int
          y: int

      function apply(entities: span[int], positions: span[Position], velocities: span[Velocity]) -> int:
          var total = 0
          for entity, position, velocity in entities, positions, velocities:
              position.x += velocity.x
              position.y += velocity.y
              total += entity
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
  end

  def test_type_checks_parallel_for_loop_in_async_function
    source = <<~MT
      # module demo.parallel_for

      import std.async as aio

      async function worker(values: span[int], other: span[int]) -> int:
          var total = 0
          for left, right in values, other:
              total += await aio.sleep(1)
              if left == right:
                  total += left
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("worker")
  end

  def test_type_checks_owned_foreign_release_after_let_else
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create() else:
              return
          win.destroy(window)
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

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_if_expression
    source = <<~MT
      # module demo.if_expr

      function main(ready: bool) -> int:
          return if ready: 1 else: 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_async_functions_and_await
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      async function parent() -> int:
          let value = await child()
          return value + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("child").type.return_type.to_s
    assert_equal "Task[int]", result.root_analysis.functions.fetch("parent").type.return_type.to_s
  end

  def test_type_checks_async_main_with_std_async_import
    source = <<~MT
      # module demo.async_main

      import std.async as aio

      async function main() -> int:
          let waited = await aio.sleep(1)
          return waited + 42
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_async_main_without_explicit_async_runtime_import
    source = <<~MT
      # module demo.async_main

      async function child() -> int:
          return 41

      async function main() -> int:
          return await child()
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_nested_await_expressions_in_async_functions
    source = <<~MT
      # module demo.async_flow

      import std.async as aio

      async function child() -> int:
          return 41

      async function main() -> int:
          return await child() + await aio.sleep(1) + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[int]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_wait_with_direct_task_expression_root
    source = <<~MT
      # module demo.async_direct_task_root

      import std.async as aio

      async function child(bonus: int) -> int:
          return await aio.sleep(1) + bonus

      function main() -> int:
          return aio.wait(child(41))
    MT

    result = check_program_source(source)

    assert_equal "int", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_async_methods
    source = <<~MT
      # module demo.async_methods

      import std.async as aio

      struct Counter:
          value: int

      extending Counter:
          async function read() -> int:
              return this.value

          async editable function bump() -> void:
              this.value += 1

      async function main() -> int:
          var counter = Counter(value = 1)
          await counter.bump()
          return await counter.read()
    MT

    result = check_program_source(source)

    counter_type = result.root_analysis.types.fetch("Counter")
    read_method = result.root_analysis.methods.fetch(counter_type).fetch("read")
    bump_method = result.root_analysis.methods.fetch(counter_type).fetch("bump")

    assert_equal "Task[int]", read_method.type.return_type.to_s
    assert_equal "Task[void]", bump_method.type.return_type.to_s
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_direct_function_identity_for_proc_parameter
    source = <<~MT
      # module demo.proc_coercion

      function apply(callback: proc(value: int) -> int, value: int) -> int:
          return callback(value)

      function times_two(value: int) -> int:
          return value * 2

      function main() -> int:
          return apply(times_two, 21)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_await_in_if_expressions_inside_async_functions
    source = <<~MT
      # module demo.async_flow

      async function child() -> int:
          return 41

      async function parent(flag: bool) -> int:
          return if flag: await child() else: 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_control_flow_in_async_functions
    source = <<~MT
      # module demo.async_flow

      import std.async as aio

      async function parent(flag: bool) -> int:
          if flag:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main") || result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_while_condition_in_async_functions
    source = <<~MT
      # module demo.async_await_in_while_cond

      import std.async as aio

      async function ready() -> bool:
          return false

      async function parent() -> int:
          while await ready():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_match_discriminant_in_async_functions
    source = <<~MT
      # module demo.async_await_in_match

      import std.async as aio

      enum Mode: int
          a = 0
          b = 1

      async function mode() -> Mode:
          return Mode.a

      async function parent() -> int:
          match await mode():
              Mode.a:
                  return 1
              Mode.b:
                  return 2
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_for_iterable_in_async_functions
    source = <<~MT
      # module demo.async_await_in_for_iterable

      import std.async as aio

      async function upper() -> int:
          return 3

      async function parent() -> int:
          var total = 0
          for i in 0..await upper():
              total += i
          return total
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_short_circuit_and_or_in_async_functions
    source = <<~MT
      # module demo.async_short_circuit

      import std.async as aio

      async function t() -> bool:
          return true

      async function f() -> bool:
          return false

      async function parent() -> int:
          if await t() and await t():
              return 1
          if await f() or await t():
              return 2
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_assignment_target_in_async_functions
    source = <<~MT
      # module demo.async_assign_target

      import std.async as aio

      async function idx() -> int:
          return 0

      async function parent() -> int:
          var values = array[int, 1](0)
          values[await idx()] = 7
          return values[0]
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_in_while_body_in_async_functions
    source = <<~MT
      # module demo.async_await_in_while

      import std.async as aio

      async function child() -> int:
          return 1

      async function parent() -> int:
          var count = 0
          var i = 0
          while i < 3:
              count = count + await child()
              i = i + 1
          return count
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_defer_in_async_functions
    source = <<~MT
      # module demo.async_defer

      import std.async as aio

      async function main() -> int:
          var total = 0
          if true:
              defer:
                  total += 2
              await aio.sleep(1)
              total += 40
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_let_else_in_async_functions
    source = <<~MT
      # module demo.async_let_else

      import std.async as aio

      async function maybe_value(handle: ptr[int]?) -> ptr[int]?:
          return handle

      async function main(handle: ptr[int]?) -> int:
          let value = await maybe_value(handle) else:
              return 0
          unsafe:
              return read(value)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_await_inside_async_defer_cleanup
    source = <<~MT
      # module demo.async_defer_await

      import std.async as aio

      async function main() -> int:
          var total = 0
          defer:
              total += await aio.sleep(1)
              total += 2
          return total
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_std_fmt_format_with_format_literal
    source = <<~MT
      # module demo.format

      import std.fmt as fmt
      import std.string as string

      function main(count: ubyte, delta: short, ticks: ulong) -> int:
          var text = fmt.format(f"count=\#{count} delta=\#{delta} ticks=\#{ticks} ok=\#{true}")
          defer text.release()
          return int<-text.len()
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_explicit_builder_format_sinks
    source = <<~MT
      # module demo.format_sink_api

      import std.fmt as fmt
      import std.string as string

      function main(value: uint, ratio: double, raw: cstr) -> int:
          var output = string.String.create()
          defer output.release()
          fmt.append_format(ref_of(output), f"hex=\#{value:x} raw=\#{raw}")
          fmt.assign_format(ref_of(output), f"ratio=\#{ratio:.2}")
          output.append_format(f" ok=\#{true}")
          output.assign_format(f"HEX=\#{value:X}")
          return int<-output.len()
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_literal_as_general_str_expression
    source = <<~MT
      # module demo.format

      function length(text: str) -> ptr_uint:
          return text.len

      function main(count: int) -> int:
          let text = f"count=\#{count}"
          if length(f"ok=\#{true}") == 0:
              return 1
          return int<-text.len
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_heredoc_literal_as_general_str_expression
    source = <<~MT
      # module demo.format_heredoc

      function length(text: str) -> ptr_uint:
          return text.len

      function main(count: int, flag: bool) -> int:
          let text = f<<-FMT
            count=\#{count}
            precise=\#{if flag: 1.0 else: 2.0:.2}
          FMT
          if length(text) == 0:
              return 1
          return int<-text.len
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_precision_spec_on_float
    source = <<~MT
      # module demo.fmt_spec

      function main(pi: double, small: float) -> int:
          let formatted_pi = f"pi=\#{pi:.2}"
          let formatted_small = f"small=\#{small:.4}"
          if formatted_pi.len == 0 or formatted_small.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_hex_spec_on_integer_and_integer_backed_enum
    source = <<~MT
      # module demo.fmt_hex

      enum State: uint
          idle = 0
          running = 1

      function main(count: int) -> int:
          let lower = f"lower=\#{count:x}"
          let upper = f"upper=\#{State.running:X}"
          if lower.len == 0 or upper.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_format_octal_and_binary_specs_on_integer_and_enum
    source = <<~MT
      # module demo.fmt_oct_bin

      flags Permission: uint
          read = 1 << 0
          write = 1 << 1

      function main(count: int) -> int:
          let octal = f"oct=\#{count:o}"
          let binary = f"bin=\#{Permission.read:B}"
          if octal.len == 0 or binary.len == 0:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_ffi_declaration_surface
    source = <<~MT
      # module demo.ffi

      enum State: ubyte
          idle = 0
          moving = 1

      flags WindowFlags: uint
          visible = 1 << 0
          fullscreen = 1 << 1

      union Number:
          i: int
          f: float

      opaque SDL_Window
      type Seconds = float
      external function get_ticks() -> Seconds
      external function open_window(title: cstr) -> SDL_Window?

      function main() -> int:
          let state: State = State.idle
          let window_flags: WindowFlags = WindowFlags.visible
          let ticks: Seconds = get_ticks()
          let window: SDL_Window? = open_window(c"demo")
          return 0
    MT

    result = check_source(source)

    assert_equal :module, result.module_kind
    assert_equal "demo.ffi", result.module_name
    assert_equal true, result.types.key?("State")
    assert_equal true, result.types.key?("WindowFlags")
    assert_equal true, result.types.key?("Number")
    assert_equal true, result.types.key?("SDL_Window")
    assert_equal true, result.functions.key?("get_ticks")
    assert_equal true, result.functions.key?("open_window")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_function_type_aliases_and_callback_arguments
    source = <<~MT
      # module demo.callbacks

      type LogCallback = fn(level: int, message: cstr) -> void
      external function set_callback(callback: LogCallback) -> void

      function on_log(level: int, message: cstr) -> void:
          return

      function main() -> int:
          set_callback(on_log)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("LogCallback")
    assert_equal true, result.functions.key?("set_callback")
    assert_equal true, result.functions.key?("on_log")
  end

  def test_type_checks_callable_value_storage_and_indirect_calls
    source = <<~MT
      # module demo.callable_values

      struct Entry:
          callback: fn(value: float) -> float

      function identity(value: int) -> int:
          return value

      function ease(value: float) -> float:
          return value + 2.0

      function main() -> int:
          let callbacks = array[fn(value: int) -> int, 1](identity)
          let entry = Entry(callback = ease)
          let callback: fn(value: float) -> float = entry.callback
          let left = callbacks[0](1)
          let right = callback(1.0)
          return left + int<-right
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_imported_function_callable_values
    root_source = <<~MT
      # module demo.main

      import std.ease as ease

      struct Entry:
          callback: fn(value: int) -> int

      function main() -> int:
          let callbacks = array[fn(value: int) -> int, 1](ease.times_two)
          let entry = Entry(callback = ease.times_two)
          return callbacks[0](3) + entry.callback(4)
    MT

    imported_sources = {
      "std/ease.mt" => <<~MT,
        # module std.ease

        public function times_two(value: int) -> int:
            return value * 2
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_closure_capture_and_param_calls
    source = <<~MT
      # module demo.proc_values

      function apply(callback: proc(value: int) -> int, value: int) -> int:
          return callback(value)

      function main() -> int:
          let offset = 4
          let callback = proc(value: int) -> int:
              return value * 2 + offset
          return apply(callback, 3)
    MT

    result = check_source(source)

    assert_equal "proc(int) -> int", result.functions.fetch("apply").type.params.fetch(0).type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_storage_in_struct_fields
    source = <<~MT
      # module demo.proc_field

      struct Holder:
          callback: proc(value: int) -> int

      function call(holder: Holder, value: int) -> int:
          return holder.callback(value)

      function main() -> int:
          let offset = 3
          let callback = proc(value: int) -> int:
              return value + offset
          let holder = Holder(callback = callback)
          return call(holder, 4)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Holder")
    assert_equal true, result.functions.key?("call")
  end

  def test_type_checks_proc_return_types
    source = <<~MT
      # module demo.proc_return

      function factory(offset: int) -> proc(value: int) -> int:
          return proc(value: int) -> int:
              return value + offset

      function main() -> int:
          let callback = factory(2)
          return callback(40)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("factory")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_assignment
    source = <<~MT
      # module demo.proc_assign

      struct Holder:
          callback: proc(value: int) -> int

      function main() -> int:
          let ca = proc(value: int) -> int:
              return value + 1
          let cb = proc(value: int) -> int:
              return value + 2
          let a = Holder(callback = ca)
          var b = Holder(callback = cb)
          b = a
          return b.callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_field_assignment
    source = <<~MT
      # module demo.proc_field_assign

      struct Holder:
          callback: proc(value: int) -> int

      function main() -> int:
          let ca = proc(value: int) -> int:
              return value + 1
          var h = Holder(callback = ca)
          let cb = proc(value: int) -> int:
              return value + 2
          h.callback = cb
          return h.callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_stored_proc_closure_values_with_ref_parameters
    source = <<~MT
      # module demo.proc_ref_storage

      struct Counter:
          value: int

      struct Entry:
          callback: proc(arg0: ref[Counter]) -> bool

      function main() -> int:
          let offset = 2
          let callback = proc(arg0: ref[Counter]) -> bool:
              arg0.value += offset
              return true
          let entry = Entry(callback = callback)
          let callbacks = array[proc(arg0: ref[Counter]) -> bool, 1](entry.callback)
          var counter = Counter(value = 0)
          if not callbacks[0](ref_of(counter)):
              return 1
          return counter.value
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_var_reassign
    source = <<~MT
      # module demo.proc_var_reassign

      function main() -> int:
          var callback = proc(value: int) -> int:
              return value + 1
          callback = proc(value: int) -> int:
              return value + 2
          return callback(0)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_async_function_with_proc_parameter
    source = <<~MT
      # module demo.async_proc_param

      async function run(callback: proc(value: int) -> int) -> int:
          return callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("run")
  end

  def test_type_checks_proc_expression_inside_async_function
    source = <<~MT
      # module demo.async_proc_expr

      async function run() -> int:
          let callback = proc(value: int) -> int:
              return value + 1
          return callback(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("run")
  end

  def test_type_checks_foreign_defs_with_boundary_mappings
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main(path: str, data: span[ubyte]) -> int:
          var data_size = 0
          rl.init_window(800, 450, "Demo")
          let loaded = rl.load_file_data(path, data_size)
          let saved = rl.save_file_data(path, data)
          if loaded != null and saved:
              return data_size
          return 0
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
        external function LoadFileData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]?
        external function SaveFileData(file_name: cstr, data: ptr[ubyte], bytes: int) -> bool
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
        public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData
        public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_cstr_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[cstr], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[str] as span[cstr], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[ptr[char]], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[str] as span[ptr[char]], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_temp_marshalling_in_return_expression
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          return sample.count_names(labels)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_span_str_temp_marshalling_in_inline_context
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function keep(value: int) -> int:
          return value

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          return keep(sample.count_names(labels))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_multi_use_mapping_in_inline_context
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function keep(value: int) -> int:
          return value

      function main() -> int:
          return keep(sample.pair_sum(1 + 2))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function pair_sum(value: int) -> int = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_in_if_expression_and_short_circuit_contexts
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[str, 3]("12", "34", "56")
          let total = if true: sample.count_names(labels) else: 0
          if false and sample.pair_sum(1 + 2) > 0:
              return 1
          return total
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function CountNames(names: ptr[ptr[char]], count: int) -> int
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function count_names(names: span[str] as span[ptr[char]]) -> int = c.CountNames(names.data, int<-names.len)
        public foreign function pair_sum(value: int) -> int = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_expression_that_already_references_params
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          return sample.pair_sum_plus_one(3)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function PairSum(left: int, right: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function pair_sum_plus_one(value: int) -> int = c.PairSum(value, value) + 1
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_cstr_to_span_ptr_char_boundary_without_scratch
    root_source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var labels = array[cstr, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function UseNames(names: ptr[ptr[char]], count: int, active: ptr[int]) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function use_names(names: span[cstr] as span[ptr[char]], inout active: int) -> int = c.UseNames(names.data, int<-names.len, active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_string_literal_without_using_scratch
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main() -> void:
          rl.init_window(800, 450, "Demo")
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_existing_cstr_without_using_scratch
    root_source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main() -> void:
          let title = c"Demo"
          rl.init_window(800, 450, title)
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        # module std.c.raylib
        external
        include "raylib.h"

        external function InitWindow(width: int, height: int, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function init_window(width: int, height: int, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_identity_pointer_projections
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main(buffer: ptr[char]) -> cstr:
          let bytes = mem.allocate_bytes(16)
          mem.release_bytes(bytes)
          mem.set_label(buffer)
          return mem.get_label()
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function AllocateBytes(size: ptr_uint) -> ptr[void]
        external function ReleaseBytes(memory: ptr[void]) -> void
        external function SetLabel(label: cstr) -> void
        external function GetLabel() -> ptr[char]
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function allocate_bytes(size: ptr_uint) -> ptr[ubyte] = c.AllocateBytes
        public foreign function release_bytes(memory: ptr[ubyte]) -> void = c.ReleaseBytes
        public foreign function set_label(label: ptr[char]) -> void = c.SetLabel
        public foreign function get_label() -> cstr = c.GetLabel
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("mem")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_opaque_handle_projections
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create()
          if window != null:
              win.destroy(window)
              return 1
          return 0
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
        public foreign function destroy(window: Window?) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_external_opaque_handle_projection_against_typed_pointer_signatures
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create()
          if window != null:
              win.destroy(window)
              if window == null:
                  return 1
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        opaque RawWindow = c"RawWindow"

        external function CreateWindow() -> ptr[RawWindow]?
        external function DestroyWindow(window: ptr[RawWindow]) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window = c"RawWindow"

        public foreign function create() -> Window? = c.CreateWindow
        public foreign function destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_out_opaque_handle_projection_against_typed_pointer_signatures
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          var window: win.Window
          if not win.create(window):
              return 1
          defer:
              win.destroy(window)
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        # module std.c.window
        external
        include "window.h"

        opaque RawWindow = c"RawWindow"

        external function CreateWindow(window: ptr[ptr[RawWindow]]?) -> bool
        external function DestroyWindow(window: ptr[RawWindow]) -> void
      MT
      "std/window.mt" => <<~MT,
        # module std.window

        import std.c.window as c

        public opaque Window = c"RawWindow"

        public foreign function create(out window: Window) -> bool = c.CreateWindow
        public foreign function destroy(window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_owned_foreign_release_inside_defer_expression
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              defer win.destroy(window)
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

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_owned_foreign_release_inside_defer_block
    root_source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> void:
          let window = win.create()
          if window != null:
              defer:
                  win.destroy(window)
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

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_mixed_numeric_binary_operators_with_arithmetic_conversion
    source = <<~MT
      # module demo.numeric_conversions

      function sum() -> double:
          return 1 + 2.5

      function before_limit() -> bool:
          return 3 < 3.5

      function main() -> int:
          if before_limit():
              return int<-sum()
          return 0
    MT

    result = check_source(source)

    assert_equal "double", result.functions.fetch("sum").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("before_limit").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_left_biased_float_literals_against_float_operands
    source = <<~MT
      # module demo.float_literal_alignment

      struct Pair:
          x: float
          y: float

      function inverse(value: float) -> float:
          let scaled = 1.0 / value
          return scaled

      function main() -> int:
          let denom: float = 4.0
          let pair = Pair(x = 1.0 / denom, y = -2.0 / denom)
          if inverse(denom) < pair.x:
              return 1
          return 0
    MT

    result = check_source(source)

    assert_equal "float", result.functions.fetch("inverse").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_span_construction_and_field_access
    source = <<~MT
      # module demo.spans

      function first(items: span[int]) -> int:
          if items.len == 0:
              return 0
          unsafe:
              return read(items.data)

      function main() -> int:
          var value = 7
          let items = span[int](data = ptr_of(value), len = 1)
          return first(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("first")
    assert_equal true, result.functions.key?("main")
    assert_equal "span[int]", result.functions.fetch("first").type.params.first.type.to_s
  end

  def test_type_checks_safe_span_indexing_and_element_assignment
    source = <<~MT
      # module demo.spans

      function bump(items: span[int]) -> int:
          let first = items[0]
          items[0] = first + 2
          return items[0]

      function main() -> int:
          var value = 7
          let items = span[int](data = ptr_of(value), len = 1)
          return bump(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("bump")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_named_constants_in_integer_type_argument_slots
    source = <<~MT
      # module demo.named_const_type_args

      const BASE: int = 28
      const CAPACITY: int = BASE + 4

      function capacity_of[N](buffer: str_buffer[N]) -> ptr_uint:
          return buffer.capacity()

      function main() -> int:
          var buffer: str_buffer[CAPACITY]
          var values = zero[array[int, CAPACITY]]
          values[0] = int<-capacity_of[CAPACITY](buffer)
          return values[0]
    MT

    result = check_source(source)

    assert_equal 32, result.values.fetch("CAPACITY").const_value
    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_fatal_statement_with_string_message
    source = <<~MT
      # module demo.fatal

      function main() -> int:
          fatal("bad state")
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_contextual_string_literals_for_cstr_surfaces
    source = <<~MT
      # module demo.literal_cstr

      external function set_text(value: cstr) -> void

      function main() -> cstr:
          let title: cstr = "hello"
          let labels = array[cstr, 2]("Layout", "Palette")
          set_text("world")
          set_text(labels[0])
          return title
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_real_str_len_slice_and_cstr_conversion
    source = <<~MT
      # module demo.str_methods

      import std.str as text_ops
      import std.mem.arena as arena

      function main() -> int:
          var scratch = arena.create(64)
          defer scratch.release()

          let text: str = "hello world"
          let part = text.slice(6, 5)
          let copied = part.to_cstr(ref_of(scratch))

          if text.len == ptr_uint<-11 and part.len == ptr_uint<-5:
              return int<-part.len
          fatal(copied)
          return 0
    MT

            program = check_program_source(source)

            assert_equal true, program.analyses_by_module_name.key?("demo.str_methods")
  end

  def test_type_checks_exhaustive_match_statement_over_enum
    source = <<~MT
      # module demo.match

      enum EventKind: ubyte
          quit = 1
          resize = 2

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
              EventKind.resize:
                  return 1

      function main() -> int:
          return dispatch(EventKind.resize)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("EventKind")
    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_for_loops_over_range_and_span
    source = <<~MT
      # module demo.for_loops

      function scan(items: span[int]) -> int:
          for i in 0..items.len:
              let index: ptr_uint = i

          for item in items:
              let value: int = item

          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("scan")
  end

  def test_type_checks_break_and_continue_inside_loop_bodies
    source = <<~MT
      # module demo.loop_control

      enum Step: ubyte
          skip = 1
          keep = 2
          stop = 3

      function add(target: ptr[int], amount: int) -> void:
          unsafe:
              read(target) += amount

      function main() -> int:
          var total = 0
          for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):
              defer add(ptr_of(total), 1)
              match step:
                  Step.skip:
                      continue
                  Step.keep:
                      total += 10
                  Step.stop:
                      break
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_break_inside_nested_loop_in_defer_block
    source = <<~MT
      # module demo.defer_loop

      function main() -> int:
          for outer in 0..1:
              defer:
                  while true:
                      break
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_layout_queries_and_static_assert
    source = <<~MT
      # module demo.layout

      struct Header:
          magic: array[ubyte, 4]
          version: ushort

      static_assert(size_of(Header) == 6, "Header size should stay stable")

      function main() -> ptr_uint:
          return offset_of(Header, version) + align_of(Header)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_layout_query_const_reuse_in_static_assert_and_type_argument_slots
    source = <<~MT
      # module demo.layout_const

      struct Header:
          magic: array[ubyte, 4]
          version: ushort

      const HEADER_SIZE: ptr_uint = size_of(Header)
      static_assert(HEADER_SIZE == 6, "Header size should stay stable")

      function main() -> int:
          var values: array[int, HEADER_SIZE]
          return 0
    MT

    result = check_source(source)

    assert_equal 6, result.values.fetch("HEADER_SIZE").const_value
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_relational_const_reuse_in_static_assert
    source = <<~MT
      # module demo.static_assert_const_compare

      const OK: bool = 1 < 2
      static_assert(OK, "ok")

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.values.fetch("OK").const_value
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_attributes_for_struct_field_and_callable_targets
    source = <<~MT
      # module demo.layout

      public attribute[field] rename(name: str)
      public attribute[callable] inline

      @[packed]
      struct Header:
          tag: ubyte
          value: uint

      @[align(16)]
      struct Mat4:
          @[rename("payload")]
          data: array[float, 16]

      static_assert(size_of(Header) == 5, "Header should stay packed")
      static_assert(offset_of(Header, value) == 1, "Header.value offset drifted")
      static_assert(align_of(Mat4) == 16, "Mat4 alignment drifted")

      @[inline]
      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_public_imported_attributes
    program = check_program_source(
      <<~MT,
        # module demo.main

        import demo.attrs as attrs

        @[attrs.traced("main")]
        function main() -> int:
            return 0
      MT
      {
        "demo/attrs.mt" => <<~MT,
          # module demo.attrs

          public attribute[callable] traced(name: str)
        MT
      },
    )

    assert_equal true, program.root_analysis.functions.key?("main")
  end

  def test_type_checks_attribute_reflection_queries
    source = <<~MT
    # module demo.attr_queries

    public attribute[field] rename(name: str)
    public attribute[callable] inline

    @[packed]
    struct Packet:
        @[rename("payload_len")]
        payload_len: uint

    @[align(16)]
    struct Mat4:
        data: array[float, 16]

    @[inline]
    function parse_packet() -> int:
        return 0

    static_assert(has_attribute(field_of(Packet, payload_len), rename), "field attribute missing")
    static_assert(
      has_attribute(field_of(Packet, payload_len), rename) and
      attribute_arg[str](attribute_of(field_of(Packet, payload_len), rename), name) == "payload_len",
      "field rename changed"
    )
    static_assert(has_attribute(callable_of(parse_packet), inline), "callable attribute missing")
    static_assert(
      has_attribute(Mat4, align) and
      attribute_arg[ptr_uint](attribute_of(Mat4, align), bytes) == 16,
      "Mat4 alignment changed"
    )
    static_assert(
      not (has_attribute(Packet, align) and attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16),
      "Packet should not have align metadata"
    )

    function aligned_bytes() -> ptr_uint:
        if has_attribute(Mat4, align):
            return attribute_arg[ptr_uint](attribute_of(Mat4, align), bytes)
        return 0

    function main() -> int:
        return parse_packet()
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_imported_attribute_reflection_queries
    source = <<~MT
      # module demo.imported_attr_queries

      import demo.net_schema as schema

      static_assert(has_attribute(schema.PlayerState, schema.replicated_rate), "imported struct attribute missing")
      static_assert(
        has_attribute(schema.PlayerState, schema.replicated_rate) and
        attribute_arg[ptr_uint](attribute_of(schema.PlayerState, schema.replicated_rate), rate_hz) == 20,
        "imported struct attribute arg changed"
      )
      static_assert(has_attribute(field_of(schema.PlayerState, hp), schema.rename), "imported field attribute missing")
      static_assert(
        has_attribute(field_of(schema.PlayerState, hp), schema.rename) and
        attribute_arg[str](attribute_of(field_of(schema.PlayerState, hp), schema.rename), name) == "health_points",
        "imported field attribute arg changed"
      )
      static_assert(has_attribute(callable_of(schema.submit_input), schema.traced), "imported callable attribute missing")
      static_assert(
        has_attribute(callable_of(schema.submit_input), schema.traced) and
        attribute_arg[str](attribute_of(callable_of(schema.submit_input), schema.traced), name) == "submit_input",
        "imported callable attribute arg changed"
      )

      function main() -> int:
          return schema.submit_input()
    MT

    imported_sources = {
      "demo/net_schema.mt" => <<~MT,
        # module demo.net_schema

        public const SNAP_RATE: ptr_uint = 20

        public attribute[struct] replicated_rate(rate_hz: ptr_uint)
        public attribute[field] rename(name: str)
        public attribute[callable] traced(name: str)

        @[replicated_rate(SNAP_RATE)]
        public struct PlayerState:
            @[rename("health_points")]
            hp: int

        @[traced("submit_input")]
        public function submit_input() -> int:
            return 7
      MT
    }

    result = check_program_source(source, imported_sources).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_explicit_casts_from_enum_and_flags_backing_values
    source = <<~MT
      # module demo.cast_values

      enum State: ubyte
          idle = 0

      flags Gesture: int
          tap = 1

      function main() -> int:
          let state = int<-State.idle
          let gesture = uint<-Gesture.tap
          return state + int<-gesture
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_flags_members_as_compile_time_constants
    source = <<~MT
      # module demo.flags_const_eval

      flags Permission: uint
          read = 1 << 0
          write = 1 << 1
          read_write = Permission.read | Permission.write

      const DEFAULT_PERMISSION: Permission = Permission.read_write

      static_assert((Permission.read | Permission.write) == Permission.read_write, "flags members should compose")
      static_assert(DEFAULT_PERMISSION == Permission.read_write, "flags consts should stay compile-time")

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_same_width_enum_and_flags_arguments_without_explicit_cast_for_extern_calls
    source = <<~MT
      # module demo.call_values

      enum State: ubyte
          idle = 0

      flags Gesture: int
          tap = 1

      external function takes_uint(value: uint) -> int
      external function takes_ubyte(value: ubyte) -> int

      function main() -> int:
          takes_uint(Gesture.tap)
          takes_ubyte(State.idle)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_integer_literals_against_expected_float_boundaries
    source = <<~MT
      # module demo.literal_float_context

      struct Point:
          x: float
          y: float

      function takes_float(value: float) -> void:
          return

      function main() -> int:
          let baseline: float = 0
          let point = Point(x = 0, y = 1)
          takes_float(0)
          return int<-(baseline + point.x)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_contextual_integer_to_float_for_non_external_call_and_field_boundaries
    source = <<~MT
      # module demo.non_external_numeric_strict

      struct Point:
          x: float

      function takes_float(value: float) -> void:
          return

      function main() -> int:
          let value = 7
          takes_float(value)
          let point = Point(x = value)
          let radians: float = value * 0.5
          takes_float(value * 0.5)
          return int<-(point.x + radians)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_contextual_integer_to_float_for_local_assignment_and_return
    source = <<~MT
      # module demo.contextual_int_to_float

      struct Point:
          x: float

      function project(value: int) -> float:
          var total: float = value
          total = value + 1
          total += value + 2
          total -= value + 3
          var point = Point(x = 0.0)
          point.x = value + 4
          return value + 5

      function main() -> int:
          let value = 4
          let baseline: float = value
          return int<-(project(value) + baseline)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("project")
  end

  def test_type_checks_contextual_float_expected_type_for_raylib_style_expressions
    source = <<~MT
      # module demo.contextual_float_raylib_style

      struct Vector2:
          x: float
          y: float

      function main() -> int:
          let button_radius: float = 30.0
          let button_step: float = button_radius * 1.5
          let player_position = Vector2(x = 100.0, y = button_radius * 1.5)
          return int<-(button_step + player_position.y)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_raygui_functions_with_raylib_shared_rectangle_type
    source = <<~MT
      # module demo.raygui_shared_rectangle

      import std.raylib as rl
      import std.raygui as gui

      function main() -> int:
          let bounds = rl.Rectangle(x = 0.0, y = 0.0, width = 120.0, height = 24.0)
          gui.label(bounds, "hello")
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_lossless_numeric_coercion_for_external_boundaries
    program = check_program_source(
      <<~MT,
        # module demo.external_numeric

        import std.c.demo as demo

        function main() -> int:
            let shade: ubyte = 200
            let count: short = 120
            let alpha: float = 0.5
            var color = demo.Color(r = shade, g = 0, b = 0, a = 255)
            color.g = shade
            demo.set_count(count)
            demo.set_opacity(alpha)
            return 0
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          struct Color:
              r: short
              g: short
              b: ubyte
              a: ubyte

          external function set_count(value: int) -> void
          external function set_opacity(value: double) -> void
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.external_numeric")
  end

  def test_type_checks_exact_compile_time_numeric_coercion_at_typed_and_external_boundaries
    program = check_program_source(
      <<~MT,
        # module demo.exact_numeric_constants

        import std.c.demo as demo

        const channel_value: int = 255

        function main() -> int:
            let whole: int = 2.0
            let local_opaque = channel_value
            demo.set_channel(local_opaque)
            demo.set_channel(demo.OPAQUE)
            demo.set_scale(200)
            return whole
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          const OPAQUE: int = 255

          external function set_channel(value: ubyte) -> void
          external function set_scale(value: float) -> void
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.exact_numeric_constants")
  end

  def test_type_checks_methods_on_opaque_receivers
    source = <<~MT
      # module demo.opaque_methods

      opaque Handle

      extending Handle:
          public function ready() -> bool:
              return true

      function main(handle: Handle) -> bool:
          return handle.ready()
    MT

    result = check_program_source(source).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_variadic_extern_calls
    source = <<~MT
      # module demo.printf

      external function printf(format: cstr, ...) -> int

      function main() -> int:
          let count = printf(c"value=%d ratio=%.1f\\n", 7, 2.5)
          return count
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_dot_dot_range_in_for_loop
    source = <<~MT
      # module demo.for_loops

      function sum(count: int) -> int:
          var total = 0
          for i in 0..count:
              total += i
          return total
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("sum")
  end

  def test_type_checks_dot_dot_range_with_ptr_uint_bounds
    source = <<~MT
      # module demo.for_loops

      function sum_n(n: ptr_uint) -> ptr_uint:
          var total: ptr_uint = 0
          for i in 0..n:
              total += i
          return total
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("sum_n")
  end

  def test_type_checks_range_index_assignment
    source = <<~MT
      # module demo.range_assign

      function fill(buf: ptr[float]) -> void:
          unsafe:
              buf[0..3] = (1.0, 2.0, 3.0)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("fill")
  end

  def test_type_checks_non_keyword_field_names
    source = <<~MT
      # module demo.keywords

      struct Event:
          kind: int

      function main(event_: Event) -> int:
          let copy = Event(kind = event_.kind)
          return copy.kind
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Event")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_extended_compound_assignment_operators
    source = <<~MT
      # module demo.compound_assignments

      flags Bits: uint
          a = 1 << 0
          b = 1 << 1

      function main() -> int:
          var value = 12
          value %= 5
          value <<= 1
          value >>= 1
          var bits = Bits.a
          bits |= Bits.b
          bits &= Bits.b
          bits ^= Bits.a
          return value
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_associated_functions_on_local_structs
    source = <<~MT
      # module demo.associated

      struct Vec:
          x: int

      extending Vec:
          static function zero() -> Vec:
              return Vec(x = 0)

          function add(other: Vec) -> Vec:
              return Vec(x = this.x + other.x)

      function main() -> int:
          let left = Vec.zero()
          let total = left.add(Vec.zero())
          return total.x
    MT

    result = check_source(source)
    vec_type = result.types.fetch("Vec")
    methods = result.methods.fetch(vec_type)

    assert_nil methods.fetch("static:zero").type.receiver_type
    assert_equal vec_type, methods.fetch("add").type.receiver_type
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_construction_for_locals_consts_and_struct_fields
    source = <<~MT
      # module demo.arrays

      struct Palette:
          colors: array[uint, 4]

      const DEFAULT: array[uint, 4] = array[uint, 4](11, 22, 33, 44)

      function main() -> int:
          let palette = array[uint, 4](1, 2, 3, 4)
          let holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.values.key?("DEFAULT")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_assignment_and_by_value_parameters
    source = <<~MT
      # module demo.arrays

      function mutate(values: array[int, 4]) -> int:
          var local = values
          unsafe:
              local[1] = 9
              return local[1]

      function main() -> int:
          var lhs = array[int, 4](1, 2, 3, 4)
          let rhs = array[int, 4](5, 6, 7, 8)
          lhs = rhs
          return mutate(lhs)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("mutate")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_local_array_return_values
    source = <<~MT
      # module demo.array_returns

      function make() -> array[int, 4]:
          return array[int, 4](1, 2, 3, 4)

      function clone(values: array[int, 4]) -> array[int, 4]:
          return values

      function read(values: array[int, 4]) -> int:
          unsafe:
              return values[1]

      function main() -> int:
          return read(clone(make()))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("make")
    assert_equal true, result.functions.key?("clone")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialization_for_arrays_and_structs
    source = <<~MT
      # module demo.zero

      struct Palette:
          colors: array[uint, 4]

      function main() -> int:
          let palette = zero[array[uint, 4]]
          let holder = zero[Palette]
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_partial_aggregate_and_array_construction
    source = <<~MT
      # module demo.partial_init

      struct Point:
          x: int
          y: int

      struct Holder:
          point: Point
          colors: array[uint, 4]

      function main() -> int:
          let origin = Point()
          let point = Point(x = 5)
          let colors = array[uint, 4](1, 2)
          let holder = Holder(point = point)
          return origin.x + point.x + int<-colors[1] + holder.point.x
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Point")
    assert_equal true, result.types.key?("Holder")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_default_specialization_with_explicit_associated_overrides
    source = <<~MT
      # module demo.default_builtin

      struct Player:
          hp: int

      extending Player:
          static function default() -> Player:
              return Player(hp = 100)

      struct Plain:
          hp: int

      extending Plain:
          static function default() -> Plain:
              return Plain(hp = 7)

      function make_default[T]() -> T:
          return default[T]

      function main() -> int:
          let player = make_default[Player]()
          let plain = make_default[Plain]()
          return player.hp + plain.hp
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Player")
    assert_equal true, result.types.key?("Plain")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_safe_array_indexing_and_element_assignment
    source = <<~MT
      # module demo.arrays

      struct Palette:
          colors: array[uint, 4]

      function main() -> int:
          var palette = array[uint, 4](1, 2, 3, 4)
          var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          palette[1] = 9
          holder.colors[2] = 10
          let first = palette[0]
          let third = holder.colors[2]
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_addr_of_fixed_array_element_through_pointer_deref
    source = <<~MT
      # module demo.ptr_arrays

      struct Palette:
          colors: array[uint, 4]

      function main() -> uint:
          var holder = Palette(colors = array[uint, 4](5, 6, 7, 8))
          unsafe:
              let base = ptr_of(holder)
              let first = ptr_of(read(base).colors[0])
              read(first) = 9
          return holder.colors[0]
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_safe_indexing_of_value_ref_array_projection
    source = <<~MT
      # module demo.good

      struct Item:
          value: int

      function project(items: ref[array[Item, 4]]) -> int:
          return read(items)[0].value

      function write(items: ref[array[Item, 4]]) -> void:
          read(items)[0].value = 7
          return
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("project")
    assert_equal true, result.functions.key?("write")
  end

  def test_type_checks_const_pointer_calls_from_immutable_storage
    source = <<~MT
      # module demo.const_pointer_call

      external function inspect(values: const_ptr[int]) -> void

      function main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_const_void_pointer_calls_from_immutable_storage
    source = <<~MT
      # module demo.const_void_pointer_call

      external function inspect(value: const_ptr[void]) -> void

      function main() -> void:
          let value = 7
          inspect(const_ptr_of(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_in_parameter
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
        external function Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_char_as_span_char_and_safe_index_source
    source = <<~MT
      # module demo.char_array_surface

      function view(items: span[char]) -> ptr_uint:
          return items.len

      function main() -> int:
          var buffer = zero[array[char, 32]]
          buffer[0] = 65
          let used = view(buffer)
          return int<-used
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_as_span_on_ordinary_call_with_lvalue_source
    source = <<~MT
      # module demo.array_span_call

      function consume(items: span[int]) -> ptr_uint:
          return items.len

      function main() -> int:
          var values = zero[array[int, 3]]
          values[0] = 1
          let used = consume(values)
          return int<-used
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialized_typed_array_char_locals
    source = <<~MT
      # module demo.char_array_zero_locals

      function main() -> int:
          var buffer: array[char, 32]
          buffer[0] = 65
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_array_char_and_span_char_ptr_char_boundary
    root_source = <<~MT
      # module demo.main

      import std.mem as mem

      function main() -> void:
          var fixed = zero[array[char, 32]]
          var dynamic = zero[array[char, 64]]
          mem.write_fixed(fixed)
          mem.write_dynamic(dynamic)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function WriteFixed(label: ptr[char]) -> void
        external function WriteDynamic(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function write_fixed(label: array[char, 32] as ptr[char]) -> void = c.WriteFixed(label)
        public foreign function write_dynamic(label: span[char] as ptr[char]) -> void = c.WriteDynamic(label)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_ro_addr_on_immutable_array_elements_for_const_pointers
    source = <<~MT
      # module demo.const_pointer_arrays

      struct Vec2:
          x: float
          y: float

      external function draw(points: const_ptr[Vec2], count: int) -> void

      function main() -> void:
          let points = array[Vec2, 2](
              Vec2(x = 1.0, y = 2.0),
              Vec2(x = 3.0, y = 4.0),
          )
          draw(const_ptr_of(points[0]), 2)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_boundary_length_pairs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer = zero[array[char, 32]]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_str_buffer_methods_and_span_char_calls
    source = <<~MT
      # module demo.str_buffer_surface

      function view(items: span[char]) -> ptr_uint:
          return items.len

      function main() -> int:
          var buffer: str_buffer[32]
          buffer.assign("hi")
          buffer.append("!")
          let text = buffer.as_str()
          let label = buffer.as_cstr()
          let raw = view(buffer)
          if text.len == 0:
              return 1
          buffer.clear()
          return int<-(raw + buffer.capacity())
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_str_buffer_format_methods
    source = <<~MT
      # module demo.str_buffer_format_surface

      function main(value: uint, ratio: double) -> int:
          var buffer: str_buffer[64]
          buffer.assign_format(f"hex=\#{value:x}")
          buffer.append_format(f" ratio=\#{ratio:.2}")
          let text = buffer.as_str()
          return int<-text.len
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_custom_format_hooks
    source = <<~MT
      # module demo.custom_format_surface

      import std.fmt as fmt
      import std.string as string

      struct Point:
          x: int
          y: int

      extending Point:
          function format_len() -> ptr_uint:
              return f"(\#{this.x}, \#{this.y})".len

          function append_format(output: ref[string.String]) -> void:
              fmt.append_format(output, f"(\#{this.x}, \#{this.y})")

      function main() -> int:
          let point = Point(x = 2, y = 3)
          let text = f"point=\#{point}"
          var output = string.String.create()
          defer output.release()
          output.append_format(f"[\#{point}]")
          var buffer: str_buffer[64]
          buffer.assign_format(f"<\#{point}>")
          fmt.assign_format(ref_of(output), f"\#{point}!")
          return int<-(text.len + buffer.len())
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_str_buffer_boundary_length_pairs
    root_source = <<~MT
      # module demo.main

      import std.ui as ui

      function main() -> void:
          var buffer: str_buffer[32]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        # module std.c.ui
        external
        include "ui.h"

        external function TextBox(text: ptr[char], text_size: int) -> void
      MT
      "std/ui.mt" => <<~MT,
        # module std.ui

        import std.c.ui as c

        public foreign function text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, int<-text_public.len)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_safe_ref_locals_params_and_methods
    source = <<~MT
      # module demo.refs

      struct Counter:
          value: int

      extending Counter:
          editable function add(delta: int):
              this.value += delta

          function read() -> int:
              return this.value

      function increment(counter: ref[Counter], amount: int) -> void:
          counter.add(amount)
          counter.value += 1

      function main() -> int:
          var counter = Counter(value = 3)
          increment(counter, 4)
          let handle = ref_of(counter)
          let value_ref = ref_of(handle.value)
          read(value_ref) += 2
          unsafe:
              let raw_counter = ptr_of(handle)
              read(raw_counter).value += 1
          return handle.read()
    MT

    result = check_source(source)

    assert_equal "ref[demo.refs.Counter]", result.functions.fetch("increment").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_ref_arguments_for_by_value_parameters
    source = <<~MT
      # module demo.ref_value_args

      struct Counter:
          value: int

      external function consume(counter: Counter) -> void

      function project(counter: Counter) -> int:
          return counter.value

      function main() -> int:
          var counter = Counter(value = 7)
          let handle = ref_of(counter)
          consume(read(handle))
          return project(read(handle))
    MT

    result = check_source(source)

    assert_equal "demo.ref_value_args.Counter", result.functions.fetch("project").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_ref_projection_without_value
    source = <<~MT
      # module demo.good

      struct Counter:
          value: int

      function main() -> int:
          var counter = Counter(value = 3)
          let handle = ref_of(counter)
          let value_ref = ref_of(handle.value)
          read(value_ref) += 2
          return handle.value
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_external_opaque_boundary_with_matching_c_name
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(logger: sample.Logger) -> void:
          sample.write_log(logger)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        # module std.c.shared
        external
        opaque va_list = c"va_list"
      MT
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        opaque va_list = c"va_list"

        external function WriteLog(args: va_list) -> void
      MT
      "std/shared.mt" => <<~MT,
        # module std.shared

        import std.c.shared as c

        public type Logger = c.va_list
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c
        import std.shared as shared

        public type Logger = shared.Logger
        public foreign function write_log(args: shared.Logger as c.va_list) -> void = c.WriteLog
      MT
    }

    program = check_program_source(source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_integer_match_with_wildcard
    source = <<~MT
      # module demo.int_match

      function dispatch(key: int) -> int:
          match key:
              65:
                  return 1
              27:
                  return 2
              _:
                  return 0

      function main() -> int:
          return dispatch(65)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_enum_match_with_wildcard_subset
    source = <<~MT
      # module demo.enum_wild

      enum EventKind: ubyte
          quit = 1
          resize = 2
          key = 3

      function dispatch(kind: EventKind) -> int:
          match kind:
              EventKind.quit:
                  return 0
              _:
                  return 1

      function main() -> int:
          return dispatch(EventKind.quit)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_integer_match_ubyte_scrutinee
    source = <<~MT
      # module demo.u8_match

      function dispatch(code: ubyte) -> int:
          match code:
              0:
                  return 0
              1:
                  return 1
              _:
                  return 99

      function main() -> int:
          return dispatch(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_exhaustive_variant_match
    source = <<~MT
      # module demo.variant_match

      variant Shape:
          circle(radius: double)
          rect(w: double, h: double)
          point

      function area(s: Shape) -> double:
          var result = 0.0
          match s:
              Shape.circle as c:
                  result = c.radius * c.radius
              Shape.rect as r:
                  result = r.w * r.h
              Shape.point:
                  result = 0.0
          return result

      function main() -> int:
          let c: Shape = Shape.circle(radius= 1.0)
          let p: Shape = Shape.point
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Shape")
    assert_equal true, result.functions.key?("area")
  end

  def test_type_checks_variant_match_with_wildcard
    source = <<~MT
      # module demo.variant_wildcard

      variant Token:
          ident(text: str)
          number(value: int)
          eof

      function is_done(t: Token) -> bool:
          match t:
              Token.eof:
                  return true
              _:
                  return false

      function main() -> int:
          let tok: Token = Token.ident(text= "hello")
          if is_done(tok):
              return 1
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Token")
    assert_equal true, result.functions.key?("is_done")
  end

  def test_type_checks_proc_fields_in_union
    source = <<~MT
      # module demo.union_proc

      union CallbackOrValue:
          callback: proc() -> int
          value: int

      function main() -> int:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("CallbackOrValue")
  end

  def test_type_checks_while_loop_with_bool_condition
    source = <<~MT
      # module demo.while_loop

      function countdown(start: int) -> int:
          var i = start
          var total = 0
          while i > 0:
              total += i
              i -= 1
          return total
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("countdown")
  end

  def test_type_checks_boolean_and_or_not_operators
    source = <<~MT
      # module demo.bool_ops

      function test_and(a: bool, b: bool) -> bool:
          return a and b

      function test_or(a: bool, b: bool) -> bool:
          return a or b

      function test_not(a: bool) -> bool:
          return not a

      function test_combined(a: bool, b: bool, c: bool) -> bool:
          return a and b or not c

      function main() -> int:
          if test_and(true, false):
              return 1
          if test_or(false, true):
              return 2
          if not test_not(true):
              return 3
          return 0
    MT

    result = check_source(source)

    assert_equal "bool", result.functions.fetch("test_and").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_or").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_not").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("test_combined").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_bitwise_operators_on_integers
    source = <<~MT
      # module demo.bitwise_ops

      function test_or(a: int, b: int) -> int:
          return a | b

      function test_and(a: int, b: int) -> int:
          return a & b

      function test_xor(a: int, b: int) -> int:
          return a ^ b

      function test_lshift(a: int, b: int) -> int:
          return a << b

      function test_rshift(a: int, b: int) -> int:
          return a >> b

      function test_complement(a: int) -> int:
          return ~a

      function main() -> int:
          return test_or(1, 2) + test_and(3, 1) + test_xor(3, 1)
    MT

    result = check_source(source)

    assert_equal "int", result.functions.fetch("test_or").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_and").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_xor").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_lshift").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_rshift").type.return_type.to_s
    assert_equal "int", result.functions.fetch("test_complement").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_modulo_operator
    source = <<~MT
      # module demo.modulo_op

      function remainder(a: int, b: int) -> int:
          return a % b

      function main() -> int:
          return remainder(10, 3)
    MT

    result = check_source(source)

    assert_equal "int", result.functions.fetch("remainder").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_event_declarations_and_methods
    source = <<~MT
      # module demo.events

      struct Resize:
          width: int
          height: int

      public event reloaded[4]

      struct Window:
          public event closed[4]
          public event resized[8](Resize)
          title: str

      function on_close() -> void:
          return

      function on_resize(value: Resize) -> void:
          return

      function attach(window: ref[Window]) -> Result[Subscription, EventError]:
          let sub = window.closed.subscribe(on_close)?
          let resized_sub = window.resized.subscribe(on_resize)?
          window.resized.unsubscribe(resized_sub)
          return window.closed.subscribe(on_close)

      function trigger(window: ref[Window]) -> Result[Subscription, EventError]:
          reloaded.subscribe(on_close)?
          reloaded.emit()
          window.closed.emit()
          window.resized.emit(Resize(width = 1, height = 2))
          return window.closed.subscribe(on_close)

      async function wait_for_resize(window: ref[Window]) -> Result[Resize, EventError]:
          return await window.resized.wait()
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("attach")
    assert_equal true, result.functions.key?("trigger")
    assert_equal true, result.functions.key?("wait_for_resize")
  end

  def test_type_checks_get_array_indexing
    source = <<~MT
      # module demo.get_array

      function main() -> int:
          var arr = array[int, 4](10, 20, 30, 40)
          let p = get(arr, 2) else:
              return 1
          return 0
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_get_span_indexing
    source = <<~MT
      # module demo.get_span

      function main() -> int:
          var value = 42
          let sp = span[int](data = ptr_of(value), len = 1)
          let p = get(sp, 0) else:
              return 1
          unsafe:
              read(p) = 99
          return value
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_match_arm_binding_shadows_outer_binding_with_same_name
    source = <<~MT
      # module demo.nested_match_shadow

      variant Outer:
          ok(value: str)
          err(code: ubyte)

      variant Inner:
          found(count: int)
          missing

      function main() -> int:
          let outer = Outer.ok(value = "hello")
          match outer:
              Outer.ok as rp:
                  let inner = Inner.found(count = 42)
                  match inner:
                      Inner.found as rp:
                          return rp.count
                      Inner.missing:
                          return -1
              Outer.err:
                  return -2
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  # ── Inline compile-time statements ────────────────────────────────────────

  def test_type_checks_inline_if_with_const_true
    source = <<~MT
      # module demo.main

      const FLAG: bool = true

      function main() -> int:
          inline if FLAG:
              return 1
          else:
              return 0
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_inline_if_with_const_false
    source = <<~MT
      # module demo.main

      const FLAG: bool = false

      function main() -> int:
          inline if FLAG:
              return 1
          else:
              return 0
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_inline_for_over_fields_of
    source = <<~MT
      # module demo.main

      struct Point:
          x: float
          y: float

      function check() -> void:
          inline for field in fields_of(Point):
              static_assert(size_of(field.type) > 0, "bad field")
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("check")
  end

  def test_type_checks_inline_match_with_const_enum
    source = <<~MT
      # module demo.main

      const BACKEND: Backend = Backend.gl

      enum Backend: ubyte
          gl = 0
          metal = 1
          vulkan = 2

      function draw() -> void:
          inline match BACKEND:
              Backend.gl:
                  return
              Backend.metal:
                  return
              Backend.vulkan:
                  return
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("draw")
  end

  def test_type_checks_when_stmt_with_const_enum
    source = <<~MT
      # module demo.main

      const TARGET: TargetOs = TargetOs.linux

      enum TargetOs: ubyte
          linux = 0
          windows = 1

      function label() -> str:
          when TARGET:
              TargetOs.linux:
                  return "linux"
              TargetOs.windows:
                  return "windows"
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("label")
  end

  # ── Const function ────────────────────────────────────────────────────────

  def test_type_checks_const_function_call_from_const
    source = <<~MT
      # module demo.main

      const function square(x: int) -> int:
          return x * x

      const V: int = square(5)

      function main() -> int:
          return V
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("square")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_const_function_at_runtime
    source = <<~MT
      # module demo.main

      const function twice(x: int) -> int:
          return x * 2

      function main() -> int:
          return twice(5)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("twice")
  end

  # ── Native math types ─────────────────────────────────────────────────────

  def test_type_checks_vec3_construction
    source = <<~MT
      # module demo.main

      function direction() -> vec3:
          return vec3(x = 1.0, y = 0.0, z = 0.0)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("direction")
  end

  def test_type_checks_vec3_field_access
    source = <<~MT
      # module demo.main

      function get_y(v: vec3) -> float:
          return v.y
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("get_y")
  end

  def test_type_checks_vec3_add
    source = <<~MT
      # module demo.main

      function add(a: vec3, b: vec3) -> vec3:
          return a + b
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("add")
  end

  def test_type_checks_vec3_scalar_multiply
    source = <<~MT
      # module demo.main

      function scale(v: vec3, s: float) -> vec3:
          return v * s
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("scale")
  end

  def test_type_checks_ivec2_construction
    source = <<~MT
      # module demo.main

      function pos() -> ivec2:
          return ivec2(x = 1, y = 2)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("pos")
  end

  def test_type_checks_mat4_construction
    source = <<~MT
      # module demo.main

      function identity() -> mat4:
          return mat4(
              col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
              col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
              col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
              col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
          )
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("identity")
  end

  def test_type_checks_quat_construction
    source = <<~MT
      # module demo.main

      function identity() -> quat:
          return quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("identity")
  end

  # ── SoA ───────────────────────────────────────────────────────────────────

  def test_type_checks_soa_type_and_index_access
    source = <<~MT
      # module demo.main

      struct Particle:
          x: float
          y: float

      function sum_x(data: SoA[Particle, 16]) -> float:
          var total: float = 0.0
          for i in 0..16:
              total += data[i].x
          return total
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("sum_x")
  end

  # ── order[T] ──────────────────────────────────────────────────────────────

  def test_type_checks_order_builtin_for_int
    source = <<~MT
      # module demo.main

      import std.hash

      function compare(a: int, b: int) -> int:
          return order[int](a, b)
    MT

    result = check_source(source)
    assert_equal true, result.functions.key?("compare")
  end

end
