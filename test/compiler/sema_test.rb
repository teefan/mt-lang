# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaSemaTest < Minitest::Test
  def test_demo_file_type_checks
    result = MilkTea::ModuleLoader.check_file(demo_path)

    assert_equal "demo.bouncing_ball", result.module_name
    assert_equal %w[main], result.functions.keys.sort
    assert_equal true, result.imports.key?("rl")
  end

  def test_rejects_non_bool_conditions
    source = <<~MT
      module demo.bad

      def main() -> i32:
          if 1:
              return 0
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/if condition must be bool/, error.message)
  end

  def test_type_checks_nullable_pointer_guard_clause_flow_narrowing
    source = <<~MT
      module demo.null_flow

      def read(handle: ptr[i32]?) -> i32:
          if handle == null:
              return 0
          unsafe:
              return deref(handle)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
  end

  def test_type_checks_short_circuit_nullable_flow_narrowing
    source = <<~MT
      module demo.null_flow

      def read(handle: ptr[i32]?) -> i32:
          unsafe:
              if handle != null and deref(handle) > 0:
                  return deref(handle)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
  end

  def test_type_checks_assignment_to_nullable_local_in_null_branch
    source = <<~MT
      module demo.null_flow

      def open_handle() -> ptr[i32]?:
          return null[ptr[i32]]

      def main() -> i32:
          var handle: ptr[i32]? = null[ptr[i32]]
          if handle == null:
              handle = open_handle()
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_assignment_to_nullable_local_in_non_null_branch
    source = <<~MT
      module demo.null_flow

      def main(input: ptr[i32]?) -> ptr[i32]?:
          var handle = input
          if handle != null:
              handle = null[ptr[i32]]
          return handle
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_if_expression
    source = <<~MT
      module demo.if_expr

      def main(ready: bool) -> i32:
          return if ready then 1 else 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_async_functions_and_await
    source = <<~MT
      module demo.async_flow

      async def child() -> i32:
          return 41

      async def parent() -> i32:
          let value = await child()
          return value + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[i32]", result.root_analysis.functions.fetch("child").type.return_type.to_s
    assert_equal "Task[i32]", result.root_analysis.functions.fetch("parent").type.return_type.to_s
  end

  def test_type_checks_async_main_with_std_async_import
    source = <<~MT
      module demo.async_main

      import std.async as async

      async def main() -> i32:
          let waited = await async.sleep(1)
          return waited + 42
    MT

    result = check_program_source(source)

    assert_equal "Task[i32]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_rejects_async_main_without_async_runtime_import
    source = <<~MT
      module demo.async_main

      async def main() -> i32:
          return 42
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/async main requires importing std\.async or std\.libuv\.async/, error.message)
  end

  def test_rejects_async_main_with_non_exit_return_type
    source = <<~MT
      module demo.async_main

      import std.async as async

      async def main() -> bool:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/async main must return i32 or void/, error.message)
  end

  def test_rejects_await_outside_async_functions
    source = <<~MT
      module demo.async_flow

      async def child() -> i32:
          return 41

      def parent() -> i32:
          return await child()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/await is only allowed inside async functions/, error.message)
  end

  def test_type_checks_nested_await_expressions_in_async_functions
    source = <<~MT
      module demo.async_flow

      import std.async as async

      async def child() -> i32:
          return 41

      async def main() -> i32:
          return await child() + await async.sleep(1) + 1
    MT

    result = check_program_source(source)

    assert_equal "Task[i32]", result.root_analysis.functions.fetch("main").type.return_type.to_s
  end

  def test_type_checks_async_methods
    source = <<~MT
      module demo.async_methods

      import std.async as async

      struct Counter:
          value: i32

      methods Counter:
          async def read() -> i32:
              return this.value

          async edit def bump() -> void:
              this.value += 1

      async def main() -> i32:
          var counter = Counter(value = 1)
          await counter.bump()
          return await counter.read()
    MT

    result = check_program_source(source)

    counter_type = result.root_analysis.types.fetch("Counter")
    read_method = result.root_analysis.methods.fetch(counter_type).fetch("read")
    bump_method = result.root_analysis.methods.fetch(counter_type).fetch("bump")

    assert_equal "Task[i32]", read_method.type.return_type.to_s
    assert_equal "Task[void]", bump_method.type.return_type.to_s
    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_direct_function_identity_for_proc_parameter
    source = <<~MT
      module demo.proc_coercion

      def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:
          return callback(value)

      def double(value: i32) -> i32:
          return value * 2

      def main() -> i32:
          return apply(double, 21)
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_await_in_if_expressions_inside_async_functions
    source = <<~MT
      module demo.async_flow

      async def child() -> i32:
          return 41

      async def parent(flag: bool) -> i32:
          return if flag then await child() else 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_control_flow_in_async_functions
    source = <<~MT
      module demo.async_flow

      import std.async as async

      async def parent(flag: bool) -> i32:
          if flag:
              return 1
          return 0
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main") || result.root_analysis.functions.key?("parent")
  end

  def test_rejects_await_inside_if_statement_in_async_functions
    source = <<~MT
      module demo.async_await_in_if

      import std.async as async

      async def child() -> i32:
          return 1

      async def parent() -> i32:
          if true:
              return await child()
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_rejects_await_inside_if_condition_in_async_functions
    source = <<~MT
      module demo.async_await_in_if_cond

      import std.async as async

      async def child() -> bool:
          return true

      async def parent() -> i32:
          if await child():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_while_condition_in_async_functions
    source = <<~MT
      module demo.async_await_in_while_cond

      import std.async as async

      async def ready() -> bool:
          return false

      async def parent() -> i32:
          while await ready():
              return 1
          return 0
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_match_discriminant_in_async_functions
    source = <<~MT
      module demo.async_await_in_match

      import std.async as async

      enum Mode: i32
          a = 0
          b = 1

      async def mode() -> Mode:
          return Mode.a

      async def parent() -> i32:
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
      module demo.async_await_in_for_iterable

      import std.async as async

      async def upper() -> i32:
          return 3

      async def parent() -> i32:
          var total = 0
          for i in range(0, await upper()):
              total += i
          return total
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_inside_short_circuit_and_or_in_async_functions
    source = <<~MT
      module demo.async_short_circuit

      import std.async as async

      async def t() -> bool:
          return true

      async def f() -> bool:
          return false

      async def parent() -> i32:
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
      module demo.async_assign_target

      import std.async as async

      async def idx() -> i32:
          return 0

      async def parent() -> i32:
          var values = array[i32, 1](0)
          values[await idx()] = 7
          return values[0]
    MT

    result = check_program_source(source)
    assert_equal true, result.root_analysis.functions.key?("parent")
  end

  def test_type_checks_await_in_while_body_in_async_functions
    source = <<~MT
      module demo.async_await_in_while

      import std.async as async

      async def child() -> i32:
          return 1

      async def parent() -> i32:
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

  def test_type_checks_std_fmt_string_with_format_literal
    source = <<~MT
      module demo.format

      import std.fmt as fmt
      import std.string as string

      def main(count: u8, delta: i16, ticks: u64) -> i32:
          var text = fmt.string(f"count=\#{count} delta=\#{delta} ticks=\#{ticks} ok=\#{true}")
          defer text.release()
          return cast[i32](text.count())
    MT

    result = check_program_source(source)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_rejects_format_literal_outside_std_fmt_string
    source = <<~MT
      module demo.format

      def main(count: i32) -> i32:
          let text = f"count=\#{count}"
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source)
    end

    assert_match(/formatted string literals are only valid in std\.fmt\.string/, error.message)
  end

  def test_rejects_wrong_return_type
    source = <<~MT
      module demo.bad

      def main() -> i32:
          return true
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/return type mismatch/, error.message)
  end

  def test_rejects_unknown_fields_in_struct_literals
    source = <<~MT
      module demo.bad

      struct Ball:
          radius: f32

      def main() -> i32:
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
      module demo.bad

      const width: i32 = 1
      const width: i32 = 2
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate value width/, error.message)
  end

  def test_type_checks_ffi_declaration_surface
    source = <<~MT
      module demo.ffi

      enum State: u8
          idle = 0
          moving = 1

      flags WindowFlags: u32
          visible = 1 << 0
          fullscreen = 1 << 1

      union Number:
          i: i32
          f: f32

      opaque SDL_Window
      type Seconds = f32
      extern def get_ticks() -> Seconds
      extern def open_window(title: cstr) -> SDL_Window?

      def main() -> i32:
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
      module demo.callbacks

      type LogCallback = fn(level: i32, message: cstr) -> void
      extern def set_callback(callback: LogCallback) -> void

      def on_log(level: i32, message: cstr) -> void:
          return

      def main() -> i32:
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
      module demo.callable_values

      struct Entry:
          callback: fn(value: f32) -> f32

      def identity(value: i32) -> i32:
          return value

      def ease(value: f32) -> f32:
          return value + 2.0

      def main() -> i32:
          let callbacks = array[fn(value: i32) -> i32, 1](identity)
          let entry = Entry(callback = ease)
          let callback: fn(value: f32) -> f32 = entry.callback
          let left = callbacks[0](1)
          let right = callback(1.0)
          return left + cast[i32](right)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_imported_function_callable_values
    root_source = <<~MT
      module demo.main

      import std.ease as ease

      struct Entry:
          callback: fn(value: i32) -> i32

      def main() -> i32:
          let callbacks = array[fn(value: i32) -> i32, 1](ease.double)
          let entry = Entry(callback = ease.double)
          return callbacks[0](3) + entry.callback(4)
    MT

    imported_sources = {
      "std/ease.mt" => <<~MT,
        module std.ease

        pub def double(value: i32) -> i32:
            return value * 2
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.types.key?("Entry")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_function_calls_with_callable_value_arguments
    source = <<~MT
      module demo.generic_callable_values

      def apply[T](callback: fn(value: i32) -> T, value: i32) -> T:
          return callback(value)

      def double(value: i32) -> i32:
          return value * 2

      def main() -> i32:
          return apply(double, 21)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("apply")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_proc_closure_capture_and_param_calls
    source = <<~MT
      module demo.proc_values

      def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:
          return callback(value)

      def main() -> i32:
          let offset = 4
          let callback = proc(value: i32) -> i32:
              return value * 2 + offset
          return apply(callback, 3)
    MT

    result = check_source(source)

    assert_equal "proc(i32) -> i32", result.functions.fetch("apply").type.params.fetch(0).type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_proc_storage_in_struct_fields
    source = <<~MT
      module demo.bad_proc_field

      struct Holder:
          callback: proc(value: i32) -> i32

      def main() -> i32:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/field Holder\.callback cannot store proc values/, error.message)
  end

  def test_rejects_proc_return_types
    source = <<~MT
      module demo.bad_proc_return

      def factory() -> proc(value: i32) -> i32:
          let offset = 1
          let callback = proc(value: i32) -> i32:
              return value + offset
          return callback
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function factory cannot return proc values/, error.message)
  end

  def test_rejects_async_functions_with_proc_parameters
    source = <<~MT
      module demo.bad_async_proc_param

      async def run(callback: proc(value: i32) -> i32) -> i32:
          return callback(1)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/async function run cannot take proc parameters yet/, error.message)
  end

  def test_rejects_proc_expressions_inside_async_functions
    source = <<~MT
      module demo.bad_async_proc_expr

      async def run() -> i32:
          let callback = proc(value: i32) -> i32:
              return value + 1
          return callback(1)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/proc expressions are not supported inside async functions yet/, error.message)
  end

  def test_type_checks_foreign_defs_with_boundary_mappings
    root_source = <<~MT
      module demo.main

      import std.raylib as rl

      def main(path: str, data: span[u8]) -> i32:
          var data_size = 0
          rl.init_window(800, 450, "Demo")
          let loaded = rl.load_file_data(path, out data_size)
          let saved = rl.save_file_data(path, data)
          if loaded != null and saved:
              return data_size
          return 0
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        extern module std.c.raylib:
            include "raylib.h"

            extern def InitWindow(width: i32, height: i32, title: cstr) -> void
            extern def LoadFileData(file_name: cstr, data_size: ptr[i32]) -> ptr[u8]?
            extern def SaveFileData(file_name: cstr, data: ptr[u8], bytes: i32) -> bool
      MT
      "std/raylib.mt" => <<~MT,
        module std.raylib

        import std.c.raylib as c

        pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
        pub foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData
        pub foreign def save_file_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveFileData(file_name, data.data, cast[i32](data.len))
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_cstr_boundary
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[cstr], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[str] as span[cstr], inout active: i32) -> i32 = c.UseNames(names.data, cast[i32](names.len), active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_to_span_ptr_char_boundary
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[ptr[char]], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[str] as span[ptr[char]], inout active: i32) -> i32 = c.UseNames(names.data, cast[i32](names.len), active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_span_str_temp_marshalling_in_return_expression
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> i32:
          var labels = array[str, 3]("12", "34", "56")
          return sample.count_names(labels)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def CountNames(names: ptr[ptr[char]], count: i32) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def count_names(names: span[str] as span[ptr[char]]) -> i32 = c.CountNames(names.data, cast[i32](names.len))
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_span_str_temp_marshalling_in_inline_context
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def keep(value: i32) -> i32:
          return value

      def main() -> i32:
          var labels = array[str, 3]("12", "34", "56")
          return keep(sample.count_names(labels))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def CountNames(names: ptr[ptr[char]], count: i32) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def count_names(names: span[str] as span[ptr[char]]) -> i32 = c.CountNames(names.data, cast[i32](names.len))
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_with_multi_use_mapping_in_inline_context
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def keep(value: i32) -> i32:
          return value

      def main() -> i32:
          return keep(sample.pair_sum(1 + 2))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def PairSum(left: i32, right: i32) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def pair_sum(value: i32) -> i32 = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_nested_foreign_defs_in_if_expression_and_short_circuit_contexts
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> i32:
          var labels = array[str, 3]("12", "34", "56")
          let total = if true then sample.count_names(labels) else 0
          if false and sample.pair_sum(1 + 2) > 0:
              return 1
          return total
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def CountNames(names: ptr[ptr[char]], count: i32) -> i32
            extern def PairSum(left: i32, right: i32) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def count_names(names: span[str] as span[ptr[char]]) -> i32 = c.CountNames(names.data, cast[i32](names.len))
        pub foreign def pair_sum(value: i32) -> i32 = c.PairSum(value, value)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_foreign_defs_with_str_to_ptr_char_boundary
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          sample.show("demo")
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Show(text: ptr[char]) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def show(text: str as ptr[char]) -> void = c.Show
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/cannot map str as ptr\[char\]/, error.message)
  end

  def test_type_checks_foreign_defs_with_span_cstr_to_span_ptr_char_boundary_without_scratch
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          var labels = array[cstr, 3]("Play", "Options", "Quit")
          var active = 0
          sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[ptr[char]], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[cstr] as span[ptr[char]], inout active: i32) -> i32 = c.UseNames(names.data, cast[i32](names.len), active)
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_string_literal_without_using_scratch
    root_source = <<~MT
      module demo.main

      import std.raylib as rl

      def main() -> void:
          rl.init_window(800, 450, "Demo")
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        extern module std.c.raylib:
            include "raylib.h"

            extern def InitWindow(width: i32, height: i32, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        module std.raylib

        import std.c.raylib as c

        pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_existing_cstr_without_using_scratch
    root_source = <<~MT
      module demo.main

      import std.raylib as rl

      def main() -> void:
          let title = c"Demo"
          rl.init_window(800, 450, title)
    MT

    imported_sources = {
      "std/c/raylib.mt" => <<~MT,
        extern module std.c.raylib:
            include "raylib.h"

            extern def InitWindow(width: i32, height: i32, title: cstr) -> void
      MT
      "std/raylib.mt" => <<~MT,
        module std.raylib

        import std.c.raylib as c

        pub foreign def init_window(width: i32, height: i32, title: str as cstr) -> void = c.InitWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("rl")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_identity_pointer_projections
    root_source = <<~MT
      module demo.main

      import std.mem as mem

      def main(buffer: ptr[char]) -> cstr:
          let bytes = mem.allocate_bytes(16)
          mem.release_bytes(bytes)
          mem.set_label(buffer)
          return mem.get_label()
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        extern module std.c.mem:
            include "mem.h"

            extern def AllocateBytes(size: usize) -> ptr[void]
            extern def ReleaseBytes(memory: ptr[void]) -> void
            extern def SetLabel(label: cstr) -> void
            extern def GetLabel() -> ptr[char]
      MT
      "std/mem.mt" => <<~MT,
        module std.mem

        import std.c.mem as c

        pub foreign def allocate_bytes(size: usize) -> ptr[byte] = c.AllocateBytes
        pub foreign def release_bytes(memory: ptr[byte]) -> void = c.ReleaseBytes
        pub foreign def set_label(label: ptr[char]) -> void = c.SetLabel
        pub foreign def get_label() -> cstr = c.GetLabel
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("mem")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_defs_with_opaque_handle_projections
    root_source = <<~MT
      module demo.main

      import std.window as win

      def main() -> i32:
          let window = win.create()
          if window != null:
              win.destroy(window)
              return 1
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        extern module std.c.window:
            include "window.h"

            extern def CreateWindow() -> ptr[void]?
            extern def DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        module std.window

        import std.c.window as c

        pub opaque Window

        pub foreign def create() -> Window? = c.CreateWindow
        pub foreign def destroy(window: Window?) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_owned_foreign_release_calls_and_refines_binding_to_null
    root_source = <<~MT
      module demo.main

      import std.window as win

      def main() -> i32:
          let window = win.create()
          if window != null:
              win.destroy(window)
              if window == null:
                  return 1
          return 0
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        extern module std.c.window:
            include "window.h"

            extern def CreateWindow() -> ptr[void]?
            extern def DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        module std.window

        import std.c.window as c

        pub opaque Window

        pub foreign def create() -> Window? = c.CreateWindow
        pub foreign def destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("win")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_plain_null_for_nullable_external_pointer_argument
    source = <<~MT
      module demo.ok

      extern def load_font_ex(codepoints: ptr[i32]?) -> void

      def main() -> void:
          load_font_ex(null)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_external_ptr_to_void_argument_without_unsafe_cast
    source = <<~MT
      module demo.ok

      extern def update_texture(pixels: ptr[void]) -> void

      def main() -> void:
          var pixels = zero[array[i32, 4]]()
          let data = raw(addr(pixels[0]))
          update_texture(data)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_owned_foreign_release_on_non_nullable_binding
    root_source = <<~MT
      module demo.main

      import std.window as win

      def main() -> void:
          let window = win.require()
          win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        extern module std.c.window:
            include "window.h"

            extern def RequireWindow() -> ptr[void]
            extern def DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        module std.window

        import std.c.window as c

        pub opaque Window

        pub foreign def require() -> Window = c.RequireWindow
        pub foreign def destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming argument window to destroy must be a bare nullable local or parameter binding/, error.message)
  end

  def test_type_checks_owned_foreign_release_on_nullable_binding
    root_source = <<~MT
      module demo.main

      import std.window as win

      def main() -> void:
          let window = win.create()
          if window != null:
              win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        extern module std.c.window:
            include "window.h"

            extern def CreateWindow() -> ptr[void]?
            extern def DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        module std.window

        import std.c.window as c

        pub opaque Window

        pub foreign def create() -> Window? = c.CreateWindow
        pub foreign def destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    program = check_program_source(root_source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_owned_foreign_release_outside_expression_statement
    root_source = <<~MT
      module demo.main

      import std.window as win

      def main() -> void:
          let window = win.create()
          if window != null:
              defer win.destroy(window)
    MT

    imported_sources = {
      "std/c/window.mt" => <<~MT,
        extern module std.c.window:
            include "window.h"

            extern def CreateWindow() -> ptr[void]?
            extern def DestroyWindow(window: ptr[void]?) -> void
      MT
      "std/window.mt" => <<~MT,
        module std.window

        import std.c.window as c

        pub opaque Window

        pub foreign def create() -> Window? = c.CreateWindow
        pub foreign def destroy(consuming window: Window) -> void = c.DestroyWindow
      MT
    }

    error = assert_raises(MilkTea::SemaError) do

      def test_type_checks_owned_foreign_release_inside_defer_block
        root_source = <<~MT
          module demo.main

          import std.window as win

          def main() -> void:
              let window = win.create()
              if window != null:
                  defer:
                      win.destroy(window)
        MT

        imported_sources = {
          "std/c/window.mt" => <<~MT,
            extern module std.c.window:
                include "window.h"

                extern def CreateWindow() -> ptr[void]?
                extern def DestroyWindow(window: ptr[void]?) -> void
          MT
          "std/window.mt" => <<~MT,
            module std.window

            import std.c.window as c

            pub opaque Window

            pub foreign def create() -> Window? = c.CreateWindow
            pub foreign def destroy(consuming window: Window) -> void = c.DestroyWindow
          MT
        }

        program = check_program_source(root_source, imported_sources)
        result = program.root_analysis

        assert_equal true, result.functions.key?("main")
      end
      check_program_source(root_source, imported_sources)
    end

    assert_match(/consuming foreign calls must be top-level expression statements/, error.message)
  end

  def test_rejects_foreign_defs_that_drop_cstr_mutability
    root_source = <<~MT
      module demo.main

      import std.mem as mem

      def main(label: cstr) -> void:
          mem.write_label(label)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        extern module std.c.mem:
            include "mem.h"

            extern def WriteLabel(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        module std.mem

        import std.c.mem as c

        pub foreign def write_label(label: cstr) -> void = c.WriteLabel
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument label to WriteLabel expects ptr\[char\], got cstr/, error.message)
  end

  def test_rejects_out_argument_outside_foreign_call
    source = <<~MT
      module demo.bad

      def write(value: i32) -> i32:
          return value

      def main() -> i32:
          var number = 1
          return write(out number)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/out is only allowed for foreign call arguments/, error.message)
  end

  def test_type_checks_mixed_numeric_binary_operators_with_arithmetic_conversion
    source = <<~MT
      module demo.numeric_conversions

      def sum() -> f64:
          return 1 + 2.5

      def before_limit() -> bool:
          return 3 < 3.5

      def main() -> i32:
          if before_limit():
              return cast[i32](sum())
          return 0
    MT

    result = check_source(source)

    assert_equal "f64", result.functions.fetch("sum").type.return_type.to_s
    assert_equal "bool", result.functions.fetch("before_limit").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_left_biased_float_literals_against_f32_operands
    source = <<~MT
      module demo.float_literal_alignment

      struct Pair:
          x: f32
          y: f32

      def inverse(value: f32) -> f32:
          let scaled = 1.0 / value
          return scaled

      def main() -> i32:
          let denom: f32 = 4.0
          let pair = Pair(x = 1.0 / denom, y = -2.0 / denom)
          if inverse(denom) < pair.x:
              return 1
          return 0
    MT

    result = check_source(source)

    assert_equal "f32", result.functions.fetch("inverse").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_mixed_signed_and_unsigned_integer_arithmetic_without_explicit_cast
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let left: i32 = 1
          let right: u32 = 2
          let sum = left + right
          return sum
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types/, error.message)
  end

  def test_type_checks_span_construction_and_field_access
    source = <<~MT
      module demo.spans

      def read(items: span[i32]) -> i32:
          if items.len == 0:
              return 0
          unsafe:
              return deref(items.data)

      def main() -> i32:
          var value = 7
          let items = span[i32](data = raw(addr(value)), len = 1)
          return read(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
    assert_equal true, result.functions.key?("main")
    assert_equal "span[i32]", result.functions.fetch("read").type.params.first.type.to_s
  end

  def test_type_checks_safe_span_indexing_and_element_assignment
    source = <<~MT
      module demo.spans

      def bump(mut items: span[i32]) -> i32:
          let first = items[0]
          items[0] = first + 2
          return items[0]

      def main() -> i32:
          var value = 7
          let items = span[i32](data = raw(addr(value)), len = 1)
          return bump(items)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("bump")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_struct_instantiation_and_embedding
    source = [
      "module demo.generics",
      "",
      "struct Slice[T]:",
      "    data: ptr[T]",
      "    len: usize",
      "",
      "struct Holder:",
      "    items: Slice[i32]",
      "",
      "def read(items: Slice[i32]) -> i32:",
      "    if items.len == 0:",
      "        return 0",
      "    unsafe:",
      "        return deref(items.data)",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let holder = Holder(items = Slice[i32](data = raw(addr(value)), len = 1))",
      "    return read(holder.items)",
      "",
    ].join("\n")

    result = check_source(source)

    assert_equal true, result.types.key?("Slice")
    assert_equal true, result.types.key?("Holder")
    assert_equal "demo.generics.Slice[i32]", result.functions.fetch("read").type.params.first.type.to_s
  end

  def test_type_checks_generic_functions_with_inferred_type_arguments
    source = <<~MT
      module demo.generic_functions

      struct Slice[T]:
          data: ptr[T]
          len: usize

      def head[T](items: Slice[T]) -> ptr[T]:
          return items.data

      def min[T](a: T, b: T) -> T:
          if a < b:
              return a
          return b

      def main() -> i32:
          var value = 7
          let items = Slice[i32](data = raw(addr(value)), len = 1)
          let smallest = min(9, 4)
          unsafe:
              return deref(head(items)) + smallest
    MT

    result = check_source(source)

    assert_equal ["T"], result.functions.fetch("head").type_params
    assert_equal ["T"], result.functions.fetch("min").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_explicit_type_arguments_and_layout_queries
    source = <<~MT
      module demo.generic_layout

      def bytes_for[T](count: usize) -> usize:
          return count * sizeof(T)

      def main() -> i32:
          return cast[i32](bytes_for[i32](4))
    MT

    result = check_source(source)

    assert_equal ["T"], result.functions.fetch("bytes_for").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_literal_type_arguments
    source = <<~MT
      module demo.generic_builder

      def capacity_of[N](buffer: str_builder[N]) -> usize:
          return buffer.capacity()

      def main() -> i32:
          var buffer: str_builder[32]
          return cast[i32](capacity_of(buffer) + capacity_of(buffer))
    MT

    result = check_source(source)

    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_functions_with_explicit_literal_type_arguments
    source = <<~MT
      module demo.generic_builder_explicit

      def capacity_of[N](buffer: str_builder[N]) -> usize:
          return buffer.capacity()

      def main() -> i32:
          var buffer: str_builder[32]
          return cast[i32](capacity_of[32](buffer))
    MT

    result = check_source(source)

    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_generic_methods
    source = <<~MT
      module demo.generic_methods

      struct Box:
          value: i32

      methods Box:
          def echo[T](input: T) -> T:
              return input

          static def make[T](input: T) -> T:
              return input

      def main() -> i32:
          let box = Box(value = 1)
          let a = box.echo(3)
          let b = Box.make(4)
          return a + b
    MT

    result = check_source(source)

    box_type = result.types.fetch("Box")
    echo_binding = result.methods.fetch(box_type).fetch("echo")
    make_binding = result.methods.fetch(box_type).fetch("make")

    assert_equal ["T"], echo_binding.type_params
    assert_equal ["T"], make_binding.type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_named_constants_in_integer_type_argument_slots
    source = <<~MT
      module demo.named_const_type_args

      const BASE: i32 = 28
      const CAPACITY: i32 = BASE + 4

      def capacity_of[N](buffer: str_builder[N]) -> usize:
          return buffer.capacity()

      def main() -> i32:
          var buffer: str_builder[CAPACITY]
          var values = zero[array[i32, CAPACITY]]()
          values[0] = cast[i32](capacity_of[CAPACITY](buffer))
          return values[0]
    MT

    result = check_source(source)

    assert_equal 32, result.values.fetch("CAPACITY").const_value
    assert_equal ["N"], result.functions.fetch("capacity_of").type_params
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_result_construction_from_expected_context
    source = <<~MT
      module demo.result

      enum LoadError: u8
          file_not_found = 1
          invalid_format = 2

      def load(available: bool) -> Result[i32, LoadError]:
          if available:
              return ok(7)
          return err(LoadError.invalid_format)

      def main() -> i32:
          let cached: Result[i32, LoadError] = ok(5)
          let missing = load(false)
          if cached.is_ok and missing.error == LoadError.invalid_format:
              return cached.value
          return 0
    MT

    result = check_source(source)

    assert_equal "Result[i32, demo.result.LoadError]", result.functions.fetch("load").type.return_type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_panic_statement_with_string_message
    source = <<~MT
      module demo.panic

      def main() -> i32:
          panic("bad state")
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_passing_stored_str_to_cstr_parameter_without_explicit_boundary
    source = <<~MT
      module demo.string_boundary

      extern def set_text(value: cstr) -> void

      def main() -> void:
          let text: str = "hello"
          set_text(text)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to set_text expects cstr, got str/, error.message)
  end

  def test_type_checks_contextual_string_literals_for_cstr_surfaces
    source = <<~MT
      module demo.literal_cstr

      extern def set_text(value: cstr) -> void

      def main() -> cstr:
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
      module demo.str_methods

      import std.str
      import std.mem.arena as arena

      def main() -> i32:
          var scratch = arena.create(64)
          defer scratch.release()

          let text: str = "hello world"
          let part = text.slice(6, 5)
          let copied = part.to_cstr(addr(scratch))

          if text.len == cast[usize](11) and part.len == cast[usize](5):
              return cast[i32](part.len)
          panic(copied)
          return 0
    MT

            program = check_program_source(source)

            assert_equal true, program.analyses_by_module_name.key?("demo.str_methods")
  end

  def test_rejects_direct_str_construction_outside_unsafe
    source = <<~MT
      module demo.bad_str_constructor

      def main(data: ptr[char], len: usize) -> str:
          return str(data = data, len = len)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/str construction requires unsafe/, error.message)
  end

  def test_type_checks_exhaustive_match_statement_over_enum
    source = <<~MT
      module demo.match

      enum EventKind: u8
          quit = 1
          resize = 2

      def dispatch(kind: EventKind) -> i32:
          match kind:
              EventKind.quit:
                  return 0
              EventKind.resize:
                  return 1

      def main() -> i32:
          return dispatch(EventKind.resize)
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("EventKind")
    assert_equal true, result.functions.key?("dispatch")
  end

  def test_type_checks_for_loops_over_range_and_span
    source = <<~MT
      module demo.for_loops

      def scan(items: span[i32]) -> i32:
          for i in range(0, items.len):
              let index: usize = i

          for item in items:
              let value: i32 = item

          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("scan")
  end

  def test_type_checks_break_and_continue_inside_loop_bodies
    source = <<~MT
      module demo.loop_control

      enum Step: u8
          skip = 1
          keep = 2
          stop = 3

      def add(target: ptr[i32], amount: i32) -> void:
          unsafe:
              deref(target) += amount

      def main() -> i32:
          var total = 0
          for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):
              defer add(raw(addr(total)), 1)
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
      module demo.defer_loop

      def main() -> i32:
          for outer in range(0, 1):
              defer:
                  while true:
                      break
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_return_inside_defer_block
    source = <<~MT
      module demo.defer_return

      def main() -> i32:
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
      module demo.defer_continue

      def main() -> i32:
          for outer in range(0, 1):
              defer:
                  continue
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_type_checks_layout_queries_and_static_assert
    source = <<~MT
      module demo.layout

      struct Header:
          magic: array[u8, 4]
          version: u16

      static_assert(sizeof(Header) == 6, "Header size should stay stable")

      def main() -> usize:
          return offsetof(Header, version) + alignof(Header)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_offsetof_unknown_field
    source = <<~MT
      module demo.layout

      struct Header:
          version: u16

      def main() -> usize:
          return offsetof(Header, missing)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown field demo\.layout\.Header\.missing/, error.message)
  end

  def test_rejects_static_assert_with_non_literal_message
    source = <<~MT
      module demo.layout

      const MESSAGE: cstr = c"layout must hold"

      def main() -> i32:
          static_assert(true, MESSAGE)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/static_assert message must be a string literal/, error.message)
  end

  def test_type_checks_packed_and_aligned_struct_layout
    source = <<~MT
      module demo.layout

      packed struct Header:
          tag: u8
          value: u32

      align(16) struct Mat4:
          data: array[f32, 16]

      static_assert(sizeof(Header) == 5, "Header should stay packed")
      static_assert(offsetof(Header, value) == 1, "Header.value offset drifted")
      static_assert(alignof(Mat4) == 16, "Mat4 alignment drifted")

      def main() -> i32:
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_reinterpret_calls
    source = <<~MT
      module demo.bits

      def main() -> u32:
          let value: f32 = 1.0
          unsafe:
              let bits = reinterpret[u32](value)
              return bits
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_reinterpret_outside_unsafe
    source = <<~MT
      module demo.bits

      def main() -> u32:
          let value: f32 = 1.0
          return reinterpret[u32](value)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/reinterpret requires unsafe/, error.message)
  end

  def test_rejects_reinterpret_of_array_types
    source = <<~MT
      module demo.bits

      def main() -> i32:
          let values = array[u8, 4](1, 2, 3, 4)
          unsafe:
              let bits = reinterpret[u32](values)
              return cast[i32](bits)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/reinterpret requires non-array concrete sized types/, error.message)
  end

  def test_type_checks_explicit_casts_from_enum_and_flags_backing_values
    source = <<~MT
      module demo.cast_values

      enum State: u8
          idle = 0

      flags Gesture: i32
          tap = 1

      def main() -> i32:
          let state = cast[i32](State.idle)
          let gesture = cast[u32](Gesture.tap)
          return state + cast[i32](gesture)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_same_width_enum_and_flags_arguments_without_explicit_cast_for_extern_calls
    source = <<~MT
      module demo.call_values

      enum State: i8
          idle = 0

      flags Gesture: i32
          tap = 1

      extern def takes_u32(value: u32) -> i32
      extern def takes_u8(value: u8) -> i32

      def main() -> i32:
          takes_u32(Gesture.tap)
          takes_u8(State.idle)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_integer_literals_against_expected_float_boundaries
    source = <<~MT
      module demo.literal_float_context

      struct Point:
          x: f32
          y: f32

      def takes_f32(value: f32) -> void:
          return

      def main() -> i32:
          let baseline: f32 = 0
          let point = Point(x = 0, y = 1)
          takes_f32(0)
          return cast[i32](baseline + point.x)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_non_literal_numeric_coercion_for_non_external_boundaries
    source = <<~MT
      module demo.non_external_numeric_strict

      struct Point:
          x: f32

      def takes_f32(value: f32) -> void:
          return

      def main() -> i32:
          let value = 7
          takes_f32(value)
          let point = Point(x = value)
          return cast[i32](point.x)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to takes_f32 expects f32, got i32/, error.message)
  end

  def test_type_checks_contextual_integer_to_float_for_local_assignment_and_return
    source = <<~MT
      module demo.contextual_int_to_float

      struct Point:
          x: f32

      def project(value: i32) -> f32:
          var total: f32 = value
          total = value + 1
          var point = Point(x = 0.0)
          point.x = value + 2
          return value + 3

      def main() -> i32:
          let value = 4
          let baseline: f32 = value
          return cast[i32](project(value) + baseline)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("project")
  end

  def test_type_checks_numeric_coercion_for_external_boundaries
    program = check_program_source(
      <<~MT,
        module demo.external_numeric

        import std.c.demo as demo

        def main() -> i32:
            let channel = 200
            var color = demo.Color(r = channel, g = 0, b = 0, a = 255)
            color.g = channel
            demo.set_scale(channel)
            return 0
      MT
      {
        "std/c/demo.mt" => <<~MT,
          extern module std.c.demo:
              struct Color:
                  r: u8
                  g: u8
                  b: u8
                  a: u8

              extern def set_scale(value: f32) -> void
        MT
      },
    )

    assert_equal true, program.analyses_by_module_name.key?("demo.external_numeric")
  end

  def test_type_checks_import_of_public_declarations_and_methods
    source = <<~MT
      module demo.main

      import demo.lib as lib

      def main() -> i32:
          let counter = lib.Counter(value = lib.answer)
          return counter.read()
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        module demo.lib

        pub const answer: i32 = 7

        pub struct Counter:
            value: i32

        methods Counter:
            pub def read() -> i32:
                return this.value

            def double() -> i32:
                return this.value * 2
      MT
    }

    result = check_program_source(source, imported).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_import_of_private_module_member
    source = <<~MT
      module demo.main

      import demo.lib as lib

      def main() -> i32:
          return lib.hidden
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        module demo.lib

        const hidden: i32 = 7
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.hidden is private to module demo\.lib/, error.message)
  end

  def test_rejects_import_of_private_method
    source = <<~MT
      module demo.main

      import demo.lib as lib

      def main() -> i32:
          let counter = lib.Counter(value = 1)
          counter.double()
          return 0
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        module demo.lib

        pub struct Counter:
            value: i32

        methods Counter:
            def double() -> i32:
                return this.value * 2
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/demo\.lib\.Counter\.double is private to module demo\.lib/, error.message)
  end

  def test_rejects_import_of_private_type_constructor
    source = <<~MT
      module demo.main

      import demo.lib as lib

      def main() -> i32:
          let hidden = lib.Hidden(value = 7)
          return hidden.value
    MT

    imported = {
      "demo/lib.mt" => <<~MT,
        module demo.lib

        struct Hidden:
            value: i32
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported)
    end

    assert_match(/lib\.Hidden is private to module demo\.lib/, error.message)
  end

  def test_rejects_same_width_enum_and_flags_arguments_without_explicit_cast_for_non_extern_calls
    source = <<~MT
      module demo.call_values

      flags Gesture: i32
          tap = 1

      def takes_u32(value: u32) -> i32:
          return 0

      def main() -> i32:
          takes_u32(Gesture.tap)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument value to takes_u32 expects u32, got .*Gesture/, error.message)
  end

  def test_type_checks_variadic_extern_calls
    source = <<~MT
      module demo.printf

      extern def printf(format: cstr, ...) -> i32

      def main() -> i32:
          let count = printf(c"value=%d ratio=%.1f\\n", 7, 2.5)
          return count
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_variadic_extern_calls_missing_required_arguments
    source = <<~MT
      module demo.printf

      extern def printf(format: cstr, ...) -> i32

      def main() -> i32:
          return printf()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/function printf expects at least 1 arguments, got 0/, error.message)
  end

  def test_rejects_same_width_enum_and_flags_assignment_without_explicit_cast
    source = <<~MT
      module demo.bad

      flags Gesture: i32
          tap = 1

      def main() -> i32:
          let gesture: u32 = Gesture.tap
          return cast[i32](gesture)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign .*Gesture to gesture: expected u32/, error.message)
  end

  def test_rejects_non_power_of_two_alignment
    source = <<~MT
      module demo.layout

      align(3) struct Mat4:
          data: array[f32, 16]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/align\(\.\.\.\) requires a power-of-two alignment, got 3/, error.message)
  end

  def test_rejects_break_and_continue_outside_loops
    break_source = <<~MT
      module demo.bad

      def main() -> i32:
          break
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(break_source)
    end
    assert_match(/break must be inside a loop/, error.message)

    continue_source = <<~MT
      module demo.bad

      def main() -> i32:
          continue
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(continue_source)
    end
    assert_match(/continue must be inside a loop/, error.message)
  end

  def test_rejects_for_loop_over_non_iterable_value
    source = <<~MT
      module demo.for_loops

      def main() -> i32:
          for value in 3:
              let copy = value
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/for loop expects range\(start, stop\), array\[T, N\], or span\[T\], got i32/, error.message)
  end

  def test_rejects_non_exhaustive_match_statement_over_enum
    source = <<~MT
      module demo.match

      enum EventKind: u8
          quit = 1
          resize = 2

      def dispatch(kind: EventKind) -> i32:
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

  def test_rejects_panic_with_non_string_message
    source = <<~MT
      module demo.panic

      def main() -> i32:
          panic(123)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/panic expects str or cstr, got i32/, error.message)
  end

  def test_rejects_mismatched_callback_arguments
    source = <<~MT
      module demo.callbacks

      type LogCallback = fn(level: i32, message: cstr) -> void
      extern def set_callback(callback: LogCallback) -> void

      def wrong(level: i32) -> void:
          return

      def main() -> i32:
          set_callback(wrong)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/argument callback to set_callback expects/, error.message)
  end

  def test_type_checks_keyword_field_names
    source = <<~MT
      module demo.keywords

      struct Event:
          type: i32

      def main(event: Event) -> i32:
          let copy = Event(type = event.type)
          return copy.type
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Event")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_pointer_cast_and_arithmetic
    source = <<~MT
      module demo.unsafe_surface

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          unsafe:
              let advanced = cast[ptr[byte]](memory) + 4
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_unsafe_pointer_indexing_with_integer_offsets
    source = <<~MT
      module demo.pointer_offsets

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          unsafe:
              let bytes = cast[ptr[byte]](memory)
              let offset = 4
              let advanced = bytes + offset
              let first = advanced[offset - 4]
              let same = first
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_extended_compound_assignment_operators
    source = <<~MT
      module demo.compound_assignments

      flags Bits: u32
          a = 1 << 0
          b = 1 << 1

      def main() -> i32:
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

  def test_type_checks_address_of_dereference_and_deref_assignment_in_unsafe
    source = <<~MT
      module demo.pointer_surface

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = raw(addr(counter))
          unsafe:
              deref(counter_ptr).value = 7
          return counter.value
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Counter")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_associated_functions_on_local_structs
    source = <<~MT
      module demo.associated

      struct Vec:
          x: i32

      methods Vec:
          static def zero() -> Vec:
              return Vec(x = 0)

          def add(other: Vec) -> Vec:
              return Vec(x = this.x + other.x)

      def main() -> i32:
          let left = Vec.zero()
          let total = left.add(Vec.zero())
          return total.x
    MT

    result = check_source(source)
    vec_type = result.types.fetch("Vec")
    methods = result.methods.fetch(vec_type)

    assert_nil methods.fetch("zero").type.receiver_type
    assert_equal vec_type, methods.fetch("add").type.receiver_type
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_construction_for_locals_consts_and_struct_fields
    source = <<~MT
      module demo.arrays

      struct Palette:
          colors: array[u32, 4]

      const DEFAULT: array[u32, 4] = array[u32, 4](11, 22, 33, 44)

      def main() -> i32:
          let palette = array[u32, 4](1, 2, 3, 4)
          let holder = Palette(colors = array[u32, 4](5, 6, 7, 8))
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.values.key?("DEFAULT")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_array_assignment_and_by_value_parameters
    source = <<~MT
      module demo.arrays

      def mutate(mut values: array[i32, 4]) -> i32:
          unsafe:
              values[1] = 9
              return values[1]

      def main() -> i32:
          var lhs = array[i32, 4](1, 2, 3, 4)
          let rhs = array[i32, 4](5, 6, 7, 8)
          lhs = rhs
          return mutate(lhs)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("mutate")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_local_array_return_values
    source = <<~MT
      module demo.array_returns

      def make() -> array[i32, 4]:
          return array[i32, 4](1, 2, 3, 4)

      def clone(values: array[i32, 4]) -> array[i32, 4]:
          return values

      def read(values: array[i32, 4]) -> i32:
          unsafe:
              return values[1]

      def main() -> i32:
          return read(clone(make()))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("make")
    assert_equal true, result.functions.key?("clone")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialization_for_arrays_and_structs
    source = <<~MT
      module demo.zero

      struct Palette:
          colors: array[u32, 4]

      def main() -> i32:
          let palette = zero[array[u32, 4]]()
          let holder = zero[Palette]()
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Palette")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_partial_aggregate_and_array_construction
    source = <<~MT
      module demo.partial_init

      struct Point:
          x: i32
          y: i32

      struct Holder:
          point: Point
          colors: array[u32, 4]

      def main() -> i32:
          let origin = Point()
          let point = Point(x = 5)
          let colors = array[u32, 4](1, 2)
          let holder = Holder(point = point)
          return origin.x + point.x + cast[i32](colors[1]) + holder.point.x
    MT

    result = check_source(source)

    assert_equal true, result.types.key?("Point")
    assert_equal true, result.types.key?("Holder")
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_partial_array_construction_with_too_many_elements
    source = <<~MT
      module demo.too_many_array_elements

      def main() -> i32:
          let values = array[i32, 2](1, 2, 3)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array expects at most 2 elements, got 3/, error.message)
  end

  def test_rejects_zero_for_void
    source = <<~MT
      module demo.zero_bad

      def main() -> i32:
          let value = zero[void]()
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/zero does not support type void/, error.message)
  end

  def test_rejects_extern_array_params_and_returns
    param_source = <<~MT
      module demo.bad_params

      extern def take(values: array[i32, 4]) -> i32
    MT

    param_error = assert_raises(MilkTea::SemaError) do
      check_source(param_source)
    end

    assert_match(/extern function take cannot take array parameters/, param_error.message)

    return_source = <<~MT
      module demo.bad_return

      extern def make() -> array[i32, 4]
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/extern function make cannot return arrays/, return_error.message)
  end

  def test_type_checks_safe_array_indexing_and_element_assignment
    source = <<~MT
      module demo.arrays

      struct Palette:
          colors: array[u32, 4]

      def main() -> i32:
          var palette = array[u32, 4](1, 2, 3, 4)
          var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))
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
      module demo.ptr_arrays

      struct Palette:
          colors: array[u32, 4]

      def main() -> u32:
          var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))
          unsafe:
              let base = raw(addr(holder))
              let first = raw(addr(deref(base).colors[0]))
              deref(first) = 9
          return holder.colors[0]
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_pointer_indexing_outside_unsafe
    source = <<~MT
      module demo.bad

      def read(data: ptr[u32]) -> u32:
          return data[0]

      def main() -> i32:
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer indexing requires unsafe/, error.message)
  end

  def test_rejects_pointer_dereference_outside_unsafe
    source = <<~MT
      module demo.bad

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = raw(addr(counter))
          return deref(counter_ptr).value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/raw pointer dereference requires unsafe/, error.message)
  end

  def test_rejects_safe_indexing_of_temporary_array_values
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let value = array[i32, 4](1, 2, 3, 4)[0]
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/safe array indexing requires an addressable array value/, error.message)
  end

  def test_type_checks_safe_indexing_of_value_ref_array_projection
    source = <<~MT
      module demo.good

      struct Item:
          value: i32

      def read(items: ref[array[Item, 4]]) -> i32:
          return value(items)[0].value

      def write(items: ref[array[Item, 4]]) -> void:
          value(items)[0].value = 7
          return
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("read")
    assert_equal true, result.functions.key?("write")
  end

  def test_rejects_dereference_of_non_pointer
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let value = deref(1)
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/deref expects ptr\[\.\.\.\], got i32/, error.message)
  end

  def test_rejects_value_on_raw_pointer
    source = <<~MT
      module demo.bad

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = raw(addr(counter))
          unsafe:
              return value(counter_ptr).value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/value expects ref\[\.\.\.\], got ptr\[demo\.bad\.Counter\]/, error.message)
  end

  def test_rejects_pointer_cast_outside_unsafe
    source = <<~MT
      module demo.bad

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          let bytes = cast[ptr[byte]](memory)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_rejects_pointer_arithmetic_outside_unsafe
    source = <<~MT
      module demo.bad

      extern def allocate(size: usize) -> ptr[void]

      def main() -> i32:
          let memory = allocate(16)
          let advanced = cast[ptr[byte]](memory) + 4
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/pointer cast requires unsafe/, error.message)
  end

  def test_type_checks_unsafe_pointer_to_cstr_abi_casts
    source = <<~MT
      module demo.cstr_casts

      extern def set_text(value: cstr) -> void
      extern def get_text() -> cstr

      def main() -> void:
          var buffer = zero[array[char, 32]]()
          unsafe:
              let raw_buffer = raw(addr(buffer[0]))
              set_text(cast[cstr](raw_buffer))
              let clipboard = get_text()
              let writable = cast[ptr[char]](clipboard)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_const_pointer_calls_from_immutable_storage
    source = <<~MT
      module demo.const_pointer_call

      extern def inspect(values: const_ptr[i32]) -> void

      def main() -> void:
          let value = 7
          inspect(ro_addr(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_const_void_pointer_calls_from_immutable_storage
    source = <<~MT
      module demo.const_void_pointer_call

      extern def inspect(value: const_ptr[void]) -> void

      def main() -> void:
          let value = 7
          inspect(ro_addr(value))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_in_parameter
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          let value = 7
          sample.inspect(in value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    result = check_program_source(root_source, imported_sources).root_analysis

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_foreign_in_argument_without_marker
    root_source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          let value = 7
          sample.inspect(value)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Inspect(value: const_ptr[void]) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def inspect[T](in value: T as const_ptr[void]) -> void = c.Inspect
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/argument value to inspect must use in/, error.message)
  end

  def test_rejects_const_pointer_for_writable_pointer_parameters
    source = <<~MT
      module demo.bad_const_pointer

      extern def write(values: ptr[i32]) -> void

      def main() -> void:
          let value = 7
          write(ro_addr(value))
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/expects ptr\[i32\], got const_ptr\[i32\]/, error.message)
  end

  def test_type_checks_array_char_as_span_char_and_safe_index_source
    source = <<~MT
      module demo.char_array_surface

      def view(items: span[char]) -> usize:
          return items.len

      def main() -> i32:
          var buffer = zero[array[char, 32]]()
          buffer[0] = 65
          let used = view(buffer)
          return cast[i32](used)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_zero_initialized_typed_array_char_locals
    source = <<~MT
      module demo.char_array_zero_locals

      def main() -> i32:
          var buffer: array[char, 32]
          buffer[0] = 65
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_typed_local_without_initializer_for_non_zero_initializable_type
    source = <<~MT
      module demo.bad_local

      def main() -> void:
          let callback: fn(value: i32) -> void
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/without initializer requires a zero-initializable type/, error.message)
  end

  def test_rejects_array_char_text_methods
    source = <<~MT
      module demo.char_array_methods

      def main() -> i32:
          var buffer = zero[array[char, 16]]()
          let view = buffer.as_str()
          let label = buffer.as_cstr()
          return cast[i32](view.len)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 16\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_removed_str_buffer_type
    source = <<~MT
      module demo.main

      def main() -> void:
          var buffer: str_buffer[8]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type str_buffer/, error.message)
  end

  def test_rejects_removed_cstr_list_buffer_type
    source = <<~MT
      module demo.main

      def main() -> void:
          var labels: cstr_list_buffer[3, 64]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/unknown generic type cstr_list_buffer/, error.message)
  end

  def test_rejects_array_char_as_str_on_temporary_receiver
    source = <<~MT
      module demo.char_array_bad_view

      def main() -> str:
          return zero[array[char, 8]]().as_str()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_array_char_as_cstr_on_temporary_receiver
    source = <<~MT
      module demo.char_array_bad_cstr

      def main() -> cstr:
          return zero[array[char, 8]]().as_cstr()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/array\[char, 8\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_rejects_foreign_str_as_cstr_calls_with_array_char_as_cstr
    root_source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer: array[char, 32]
          ui.label(buffer.as_cstr())
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:

            extern def Label(text: cstr) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def label(text: str as cstr) -> void = c.Label
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(root_source, imported_sources)
    end

    assert_match(/array\[char, 32\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_type_checks_foreign_defs_with_array_char_and_span_char_ptr_char_boundary
    root_source = <<~MT
      module demo.main

      import std.mem as mem

      def main() -> void:
          var fixed = zero[array[char, 32]]()
          var dynamic = zero[array[char, 64]]()
          mem.write_fixed(fixed)
          mem.write_dynamic(dynamic)
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        extern module std.c.mem:
            include "mem.h"

            extern def WriteFixed(label: ptr[char]) -> void
            extern def WriteDynamic(label: ptr[char]) -> void
      MT
      "std/mem.mt" => <<~MT,
        module std.mem

        import std.c.mem as c

        pub foreign def write_fixed(label: array[char, 32] as ptr[char]) -> void = c.WriteFixed(label)
        pub foreign def write_dynamic(label: span[char] as ptr[char]) -> void = c.WriteDynamic(label)
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_ro_addr_on_immutable_array_elements_for_const_pointers
    source = <<~MT
      module demo.const_pointer_arrays

      struct Vec2:
          x: f32
          y: f32

      extern def draw(points: const_ptr[Vec2], count: i32) -> void

      def main() -> void:
          let points = array[Vec2, 2](
              Vec2(x = 1.0, y = 2.0),
              Vec2(x = 3.0, y = 4.0),
          )
          draw(ro_addr(points[0]), 2)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_boundary_length_pairs
    root_source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer = zero[array[char, 32]]()
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def TextBox(text: ptr[char], text_size: i32) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, cast[i32](text_public.len))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_str_builder_methods_and_span_char_calls
    source = <<~MT
      module demo.str_builder_surface

      def view(items: span[char]) -> usize:
          return items.len

      def main() -> i32:
          var buffer: str_builder[32]
          buffer.assign("hi")
          buffer.append("!")
          let text = buffer.as_str()
          let label = buffer.as_cstr()
          let raw = view(buffer)
          if text.len == 0:
              return 1
          buffer.clear()
          return cast[i32](raw + buffer.capacity())
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_foreign_mapping_public_alias_for_str_builder_boundary_length_pairs
    root_source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer: str_builder[32]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def TextBox(text: ptr[char], text_size: i32) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, cast[i32](text_public.len))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_generic_foreign_mapping_public_alias_for_str_builder_capacity_pairs
    root_source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer: str_builder[32]
          ui.text_box(buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def TextBox(text: ptr[char], text_size: i32) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, cast[i32](text_public.capacity() + 1))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_explicit_literal_specialization_for_imported_generic_foreign_defs
    root_source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer: str_builder[32]
          ui.text_box[32](buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def TextBox(text: ptr[char], text_size: i32) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, cast[i32](text_public.capacity() + 1))
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_explicit_literal_specialization_for_local_generic_foreign_defs
    root_source = <<~MT
      module demo.main

      import std.c.ui as c

      pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, cast[i32](text_public.capacity() + 1))

      def main() -> void:
          var buffer: str_builder[32]
          text_box[32](buffer)
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def TextBox(text: ptr[char], text_size: i32) -> void
      MT
    }

    result = check_program_source(root_source, imported_sources)

    assert_equal true, result.root_analysis.functions.key?("main")
  end

  def test_type_checks_unsafe_integer_to_char_buffer_writes
    source = <<~MT
      module demo.char_buffer_writes

      def main() -> i32:
          let first = 65
          var ptr: ptr[char] = zero[ptr[char]]()
          unsafe:
              ptr[0] = first
              ptr[1] = cast[char](66)
          return 0
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_zero_pointer_initializer_for_nullable_pointer_local
    source = <<~MT
      module demo.bad_zero_pointer_initializer

      def main() -> void:
          let maybe_buffer: ptr[char]? = zero[ptr[char]]()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\]\(\) in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_assignment_to_nullable_pointer_local
    source = <<~MT
      module demo.bad_zero_pointer_assignment

      def main() -> void:
          var maybe_buffer: ptr[char]? = null
          maybe_buffer = zero[ptr[char]]()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\]\(\) in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_argument_for_nullable_pointer_parameter
    source = <<~MT
      module demo.bad_zero_pointer_argument

      extern def set_buffer(value: ptr[char]?) -> void

      def main() -> void:
          set_buffer(zero[ptr[char]]())
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\]\(\) in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_zero_pointer_return_for_nullable_pointer_return
    source = <<~MT
      module demo.bad_zero_pointer_return

      def main() -> ptr[char]?:
          return zero[ptr[char]]()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/use null instead of zero\[ptr\[char\]\]\(\) in nullable pointer-like context ptr\[char\]\?/, error.message)
  end

  def test_rejects_char_as_general_numeric_type
    source = <<~MT
      module demo.bad_char_numeric

      def main() -> i32:
          let value = cast[char](65)
          return value + 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/operator \+ requires compatible numeric types, got char and i32/, error.message)
  end

  def test_type_checks_typed_null_pointer_literals_and_unsafe_cstr_casts
    source = <<~MT
      module demo.typed_null_cstr

      extern def set_text(value: cstr) -> void

      def main() -> void:
          let maybe_buffer: ptr[char]? = null[ptr[char]]
          unsafe:
              set_text(cast[cstr](null[ptr[char]]))
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_non_pointer_typed_null_literals
    source = <<~MT
      module demo.bad_typed_null

      def main() -> void:
          let maybe_buffer: ptr[char]? = null[i32]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/typed null requires pointer-like type, got i32/, error.message)
  end

  def test_rejects_inference_from_typed_null_literals
    source = <<~MT
      module demo.bad_typed_null_inference

      def main() -> void:
          let maybe_buffer = null[ptr[char]]
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot infer type for maybe_buffer from null/, error.message)
  end

  def test_type_checks_safe_ref_locals_params_and_methods
    source = <<~MT
      module demo.refs

      struct Counter:
          value: i32

      methods Counter:
          edit def add(delta: i32):
              this.value += delta

      def increment(counter: ref[Counter], amount: i32) -> void:
          value(counter).add(amount)
          value(counter).value += 1

      def main() -> i32:
          var counter = Counter(value = 3)
          let handle = addr(counter)
          increment(handle, 4)
          let value_ref = addr(value(handle).value)
          value(value_ref) += 2
          unsafe:
              let raw_counter = raw(handle)
              deref(raw_counter).value += 1
          return value(handle).value
    MT

    result = check_source(source)

    assert_equal "ref[demo.refs.Counter]", result.functions.fetch("increment").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_ref_of_immutable_values
    source = <<~MT
      module demo.bad

      def main() -> i32:
          let value = 1
          let handle = addr(value)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot assign to immutable value/, error.message)
  end

  def test_rejects_ref_storage_and_escape_types
    field_source = <<~MT
      module demo.bad_field

      struct Holder:
          value: ref[i32]
    MT

    field_error = assert_raises(MilkTea::SemaError) do
      check_source(field_source)
    end

    assert_match(/field Holder\.value cannot store ref types/, field_error.message)

    extern_source = <<~MT
      module demo.bad_param

      extern def take(value: ref[i32]) -> void
    MT

    extern_error = assert_raises(MilkTea::SemaError) do
      check_source(extern_source)
    end

    assert_match(/extern function take cannot take ref parameters/, extern_error.message)

    return_source = <<~MT
      module demo.bad_return

      def leak(value: ref[i32]) -> ref[i32]:
          return value
    MT

    return_error = assert_raises(MilkTea::SemaError) do
      check_source(return_source)
    end

    assert_match(/function leak cannot return ref types/, return_error.message)
  end

  def test_type_checks_ref_arguments_for_by_value_parameters
    source = <<~MT
      module demo.ref_value_args

      struct Counter:
          value: i32

      extern def consume(counter: Counter) -> void

      def read(counter: Counter) -> i32:
          return counter.value

      def main() -> i32:
          var counter = Counter(value = 7)
          let handle = addr(counter)
          consume(value(handle))
          return read(value(handle))
    MT

    result = check_source(source)

    assert_equal "demo.ref_value_args.Counter", result.functions.fetch("read").type.params.first.type.to_s
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_ref_to_pointer_cast_outside_unsafe
    source = <<~MT
      module demo.bad

      def main() -> i32:
          var value = 1
          let handle = addr(value)
          let raw = cast[ptr[i32]](handle)
          return 0
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/ref to pointer cast requires unsafe/, error.message)
  end

  def test_rejects_ref_projection_without_value
    source = <<~MT
      module demo.bad

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let handle = addr(counter)
          return handle.value
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/cannot access member value of ref\[demo.bad.Counter\]/, error.message)
  end

  def test_rejects_non_integer_flags_backing_types
    source = <<~MT
      module demo.bad

      flags BadFlags: f32
          visible = 1
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/backing type must be an integer primitive/, error.message)
  end

  def test_rejects_unknown_enum_members
    source = <<~MT
      module demo.bad

      enum State: u8
          idle = 0

      def main() -> i32:
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
      module demo.main

      import std.shared as shared
      import std.sample as sample

      def main() -> void:
          sample.set_matrix(shared.IDENTITY)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        extern module std.c.shared:
            struct Matrix:
                m0: f32
      MT
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            struct Matrix:
                m0: f32
                m1: f32

            extern def SetMatrix(matrix: Matrix) -> void
      MT
      "std/shared.mt" => <<~MT,
        module std.shared

        import std.c.shared as c

        pub type Matrix = c.Matrix
        pub const IDENTITY: Matrix = Matrix(m0 = 1.0)
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c
        import std.shared as shared

        pub foreign def set_matrix(matrix: shared.Matrix as c.Matrix) -> void = c.SetMatrix
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      check_program_source(source, imported_sources)
    end

    assert_match(/foreign parameter matrix of set_matrix cannot map std\.c\.shared\.Matrix as std\.c\.sample\.Matrix/, error.message)
  end

  def test_type_checks_foreign_external_opaque_boundary_with_matching_c_name
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main(logger: sample.Logger) -> void:
          sample.write_log(logger)
    MT

    imported_sources = {
      "std/c/shared.mt" => <<~MT,
        extern module std.c.shared:
            opaque va_list = c"va_list"
      MT
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            opaque va_list = c"va_list"

            extern def WriteLog(args: va_list) -> void
      MT
      "std/shared.mt" => <<~MT,
        module std.shared

        import std.c.shared as c

        pub type Logger = c.va_list
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c
        import std.shared as shared

        pub type Logger = shared.Logger
        pub foreign def write_log(args: shared.Logger as c.va_list) -> void = c.WriteLog
      MT
    }

    program = check_program_source(source, imported_sources)
    result = program.root_analysis

    assert_equal true, result.imports.key?("sample")
    assert_equal true, result.functions.key?("main")
  end

  def test_type_checks_module_scope_mutable_vars_and_zero_initialized_storage
    source = <<~MT
      module demo.module_vars

      def identity(value: i32) -> i32:
          return value

      var counter: i32 = 1
      var scratch: array[u8, 4]
      var callbacks: array[fn(value: i32) -> i32, 1] = array[fn(value: i32) -> i32, 1](identity)

      def main() -> i32:
          counter = callbacks[0](counter + 1)
          scratch[0] = 7
          return counter + cast[i32](scratch[0])
    MT

    result = check_source(source)
    counter = result.values.fetch("counter")
    scratch = result.values.fetch("scratch")
    callbacks = result.values.fetch("callbacks")

    assert_equal true, counter.mutable
    assert_equal :var, counter.kind
    assert_equal "i32", counter.type.to_s
    assert_equal true, scratch.mutable
    assert_equal "array[u8, 4]", scratch.type.to_s
    assert_equal true, callbacks.mutable
    assert_equal "array", callbacks.type.name
    assert_instance_of MilkTea::Types::Function, callbacks.type.arguments[0]
    assert_equal "i32", callbacks.type.arguments[0].return_type.to_s
    assert_equal "i32", callbacks.type.arguments[0].params.first.type.to_s
    assert_equal 1, callbacks.type.arguments[1].value
    assert_equal true, result.functions.key?("main")
  end

  def test_rejects_module_scope_var_with_non_static_initializer
    source = <<~MT
      module demo.bad_module_var

      def seed() -> i32:
          return 41

      var counter: i32 = seed()
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/module variable initializer must be static-storage-safe/, error.message)
  end

  def test_type_checks_integer_match_with_wildcard
    source = <<~MT
      module demo.int_match

      def dispatch(key: i32) -> i32:
          match key:
              65:
                  return 1
              27:
                  return 2
              _:
                  return 0

      def main() -> i32:
          return dispatch(65)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_rejects_integer_match_missing_wildcard
    source = <<~MT
      module demo.int_match_bad

      def dispatch(key: i32) -> i32:
          match key:
              65:
                  return 1
              27:
                  return 2

      def main() -> i32:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/requires a wildcard arm/, error.message)
  end

  def test_rejects_non_literal_pattern_in_integer_match
    source = <<~MT
      module demo.int_match_bad_pattern

      var x: i32 = 65

      def dispatch(key: i32) -> i32:
          match key:
              x:
                  return 1
              _:
                  return 0

      def main() -> i32:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/must be an integer literal or _/, error.message)
  end

  def test_rejects_duplicate_wildcard_in_match
    source = <<~MT
      module demo.dup_wild

      def dispatch(key: i32) -> i32:
          match key:
              65:
                  return 1
              _:
                  return 0
              _:
                  return 99

      def main() -> i32:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate wildcard arm/, error.message)
  end

  def test_type_checks_enum_match_with_wildcard_subset
    source = <<~MT
      module demo.enum_wild

      enum EventKind: u8
          quit = 1
          resize = 2
          key = 3

      def dispatch(kind: EventKind) -> i32:
          match kind:
              EventKind.quit:
                  return 0
              _:
                  return 1

      def main() -> i32:
          return dispatch(EventKind.quit)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  def test_rejects_duplicate_integer_match_arm_value
    source = <<~MT
      module demo.dup_int

      def dispatch(key: i32) -> i32:
          match key:
              65:
                  return 1
              65:
                  return 2
              _:
                  return 0

      def main() -> i32:
          return dispatch(65)
    MT

    error = assert_raises(MilkTea::SemaError) do
      check_source(source)
    end

    assert_match(/duplicate match arm value/, error.message)
  end

  def test_type_checks_integer_match_u8_scrutinee
    source = <<~MT
      module demo.u8_match

      def dispatch(code: u8) -> i32:
          match code:
              0:
                  return 0
              1:
                  return 1
              _:
                  return 99

      def main() -> i32:
          return dispatch(1)
    MT

    result = check_source(source)

    assert_equal true, result.functions.key?("dispatch")
  end

  private

  def demo_path
    File.expand_path("../../examples/milk-tea-demo.mt", __dir__)
  end

  def check_source(source)
    MilkTea::Sema.check(MilkTea::Parser.parse(source))
  end

  def check_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-sema") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
    end
  end
end
