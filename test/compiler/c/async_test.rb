# frozen_string_literal: true

require_relative "helpers"

class AsyncTest < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_parallel_collection_for_loop_in_async_function
    source = <<~MT
      # module demo.async_parallel_for

      import std.async as aio

      async function worker(values: span[int], other: span[int]) -> int:
          var total = 0
          for left, right in values, other:
              total += await aio.sleep(1)
              total += left + right
          return total
    MT

    generated = generate_c_from_source(source)

    assert_match(/demo_async_parallel_for_worker__frame/, generated)
    assert_match(/if \(__mt_frame->for_iterable_[A-Za-z0-9_]+\.len != __mt_frame->for_iterable_[A-Za-z0-9_]+\.len\)/, generated)
    assert_match(/__mt_frame->local_left = __mt_frame->for_iterable_[A-Za-z0-9_]+\.data\[__mt_frame->for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/__mt_frame->local_right = __mt_frame->for_iterable_[A-Za-z0-9_]+\.data\[__mt_frame->for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/resume_state_1:/, generated)
  end

  def test_generate_c_for_async_methods
    source = <<~MT
      # module demo.async_methods_codegen

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

    generated = generate_c_from_program_source(source)

    assert_match(/demo_async_methods_codegen_Counter_bump__frame/, generated)
    assert_match(/demo_async_methods_codegen_Counter_read__frame/, generated)
    assert_match(/demo_async_methods_codegen_Counter_bump\(&__mt_frame->local_counter\)/, generated)
    assert_match(/demo_async_methods_codegen_Counter_read\(__mt_frame->local_counter\)/, generated)
  end

  def test_generate_c_for_async_with_control_flow
    source = <<~MT
      # module demo.async_flow_codegen

      import std.async as aio

      async function sum_range(limit: int) -> int:
          var total: int = 0
          for i in 0..limit:
              total += i
          return total

      async function clamp_sum(limit: int) -> int:
          let total = await sum_range(limit)
          if total > 100:
              return 100
          else if total < 0:
              return 0
          else:
              return total

      async function main() -> int:
          return await clamp_sum(20)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_async_flow_codegen_sum_range__frame/, generated)
    assert_match(/demo_async_flow_codegen_clamp_sum__frame/, generated)
    assert_match(/while\s*\(/, generated)
    assert_match(/total\s*\+=/, generated)
  end

  def test_generate_c_for_async_function_without_await_omits_state_dispatch
    source = <<~MT
      # module demo.noawait_async_codegen

      async function main() -> int:
          var total = 0
          if true:
              total = 7
          return total
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_noawait_async_codegen___async_main__frame/, generated)
    refute_match(/switch \(__mt_frame->state\)/, generated)
    refute_match(/resume_state_0:/, generated)
    refute_match(/goto demo_noawait_async_codegen___async_main__resume_state_0;/, generated)
    refute_match(/typedef struct demo_noawait_async_codegen___async_main__frame \{[^}]*\bstate;/m, generated)
  end

    def test_generate_c_for_await_in_if_body
      source = <<~MT
        # module demo.await_in_if

        import std.async as aio

        async function child() -> int:
            return 42

        async function parent() -> int:
            if true:
                return await child()
            return 0
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_in_if_parent__frame/, generated)
      assert_match(/case 0/, generated)
      assert_match(/case 1/, generated)
      assert_match(/if\s*\(/, generated)
      assert_match(/demo_await_in_if_parent__resume_state_1:/, generated)
    end

    def test_generate_c_for_await_in_while_body
      source = <<~MT
        # module demo.await_in_while

        import std.async as aio

        async function tick() -> int:
            return 1

        async function accumulate(limit: int) -> int:
            var total = 0
            var i = 0
            while i < limit:
                total = total + await tick()
                i = i + 1
            return total
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_in_while_accumulate__frame/, generated)
      assert_match(/case 1/, generated)
      assert_match(/while\s*\(/, generated)
      assert_match(/demo_await_in_while_accumulate__resume_state_1:/, generated)
    end

      def test_generate_c_for_defer_in_async_function
        source = <<~MT
          # module demo.async_defer_codegen

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

        generated = generate_c_from_program_source(source)

        assert_match(/demo_async_defer_codegen___async_main__frame/, generated)
        assert_match(/demo_async_defer_codegen___async_main__resume_state_1:/, generated)
        assert_match(/local_total/, generated)
        assert_match(/\+= 2;/, generated)
      end

      def test_generate_c_for_await_in_async_defer_cleanup
        source = <<~MT
          # module demo.async_defer_await_codegen

          import std.async as aio

          async function main() -> int:
              var total = 0
              if true:
                  defer:
                      total += await aio.sleep(1)
                      total += 2
                  total += 40
              return total
        MT

        generated = generate_c_from_program_source(source)

        assert_match(/demo_async_defer_await_codegen___async_main__frame/, generated)
        assert_match(/demo_async_defer_await_codegen___async_main__resume_state_1:/, generated)
        assert_match(/local_total/, generated)
        assert_match(/\+= 2;/, generated)
      end

      def test_generate_c_for_let_else_in_async_function
        source = <<~MT
          # module demo.async_let_else_codegen

          import std.async as aio

          async function maybe_value(handle: ptr[int]?) -> ptr[int]?:
              return handle

          async function main(handle: ptr[int]?) -> int:
              let value = await maybe_value(handle) else:
                  return 0
              unsafe:
                  return read(value)
        MT

        generated = generate_c_from_program_source(source)

        assert_match(/demo_async_let_else_codegen___async_main__frame/, generated)
        assert_match(/local_value/, generated)
        assert_match(/if \(.*local_value == NULL\)/, generated)
        assert_match(/resume_state_1:/, generated)
      end

    def test_generate_c_for_await_in_if_condition
      source = <<~MT
        # module demo.await_in_if_condition

        import std.async as aio

        async function ready() -> bool:
            return true

        async function parent() -> int:
            if await ready():
                return 1
            return 0
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_in_if_condition_parent__frame/, generated)
      assert_match(/case 1/, generated)
      assert_match(/demo_await_in_if_condition_parent__resume_state_1:/, generated)
    end

    def test_generate_c_for_await_in_short_circuit
      source = <<~MT
        # module demo.await_short_circuit

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

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_short_circuit_parent__frame/, generated)
      assert_match(/resume_state_1:/, generated)
      assert_match(/resume_state_2:/, generated)
    end

    def test_generate_c_for_await_in_if_expression
      source = <<~MT
        # module demo.await_if_expr

        import std.async as aio

        async function child() -> int:
            return 7

        async function parent(flag: bool) -> int:
            return if flag: await child() else: 0
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_if_expr_parent__frame/, generated)
      assert_match(/resume_state_1:/, generated)
      assert_match(/if\s*\(/, generated)
    end

    def test_generate_c_for_await_in_format_string
      source = <<~'MT'
        # module demo.await_format_string

        async function value() -> double:
            return 3.14159

        async function parent() -> str:
            return f"pi=#{await value():.2}"
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_format_string_parent__frame/, generated)
      assert_match(/resume_state_1:/, generated)
      assert_match(/mt_format_append_double_precision\(/, generated)
      assert_match(/,\s*2\s*\)/, generated)
    end

  def test_generate_c_for_deferred_literal_return_without_spill_temp
    source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main() -> int:
          rl.init_window(800, 450, "Demo")
          defer rl.close_window()
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/CloseWindow\(\);\s+(?:#[^\n]*\n\s+)?return 0;/m, generated)
    refute_match(/__mt_return_value_\d+/, generated)
  end

  def test_generate_c_for_async_let_else_status_void_discard_binding
    source = <<~MT
      # module demo.async_status_void_codegen

      import std.async as aio


      function done() -> void:
          return

      async function parse(flag: int) -> Result[void, int]:
          await aio.sleep(1)
          if flag < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      async function main(flag: int) -> int:
          let _ = await parse(flag) else as error:
              return error
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_async_status_void_codegen___async_main__frame/, generated)
    assert_match(/local_let_else_discard_\d+/, generated)
    assert_match(/if \(.*kind == Result_void_int_kind_failure\)/, generated)
    assert_match(/data\.failure\.error;/, generated)
  end

  def test_generate_c_for_async_result_propagation_expression
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      async function render(input: int) -> Result[str, int]:
          let value = parse(input)?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/Result_int_int __mt_propagate_\d+ = demo_main_parse\([^\)]*\);/, generated)
    assert_match(/if \(__mt_propagate_\d+\.kind == Result_int_int_kind_failure\)/, generated)
    assert_match(/__mt_frame->result = \(Result_str_int\)\{ \.kind = Result_str_int_kind_failure, \.data\.failure = \(struct Result_str_int_failure\)\{ \.error = __mt_propagate_\d+\.data\.failure\.error \} \};/, generated)
    assert_match(/__mt_frame->ready = true;/, generated)
    refute_match(/return \(Result_str_int\)\{ \.kind = Result_str_int_kind_failure/, generated)
  end

  def test_generate_c_for_async_result_propagation_over_await_expression
    source = <<~MT
      # module demo.main

      import std.async as aio


      async function parse(input: int) -> Result[int, int]:
          await aio.sleep(1)
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      async function render(input: int) -> Result[str, int]:
          let value = (await parse(input))?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/take_result\([^\)]*\);/, generated)
    assert_match(/Result_int_int __mt_propagate_\d+ = __mt_frame->local___mt_async_tmp_\d+;/, generated)
    assert_match(/__mt_frame->result = \(Result_str_int\)\{ \.kind = Result_str_int_kind_failure, \.data\.failure = \(struct Result_str_int_failure\)\{ \.error = __mt_propagate_\d+\.data\.failure\.error \} \};/, generated)
  end

  def test_generate_c_for_async_result_void_propagation_statement
    source = <<~MT
      # module demo.main



      function done() -> void:
          return

      function parse(flag: int) -> Result[void, int]:
          if flag < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      async function verify(flag: int) -> Result[void, int]:
          parse(flag)?
          return Result[void, int].success(value= done())
    MT

    generated = generate_c_from_program_source(source)

  assert_match(/Result_void_int __mt_propagate_\d+ = demo_main_parse\([^\)]*\);/, generated)
    assert_match(/if \(__mt_propagate_\d+\.kind == Result_void_int_kind_failure\)/, generated)
    assert_match(/__mt_frame->result = __mt_propagate_\d+;/, generated)
    assert_match(/__mt_frame->ready = true;/, generated)
    refute_match(/return __mt_propagate_\d+;/, generated)
    refute_match(/__mt_propagate_\d+\.data\.success\.value/, generated)
  end

  def test_generate_c_for_defer_expression_owned_foreign_release_calls
    source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create()
          if window == null:
              return 0
          defer win.destroy(window)
          return 1
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/std_window_Window\* window = CreateWindow\(\);/, generated)
    assert_match(/if \(window == NULL\)/, generated)
    assert_match(/DestroyWindow\(window\);/, generated)
    assert_match(/window = NULL;/, generated)
  end

  def test_generate_c_for_async_await_of_task_locals_without_redundant_await_slots
    source = <<~MT

# module demo.async_clean

import std.async as aio

async function child() -> int:
    let task = aio.sleep(1)
    return await task + 1

    MT

    generated = generate_c_from_source(source)

    assert_match(/mt_task_int local_task;/, generated)
    refute_match(/mt_task_int await_0;/, generated)
    refute_match(/__mt_frame->await_0 = __mt_frame->local_task;/, generated)
    assert_match(/if \(!__mt_frame->local_task\.ready\(__mt_frame->local_task\.frame\)\)/, generated)
    assert_match(/__mt_frame->local___mt_async_tmp_1 = __mt_frame->local_task\.take_result\(__mt_frame->local_task\.frame\);/, generated)
    assert_match(/__mt_frame->result = __mt_frame->local___mt_async_tmp_1 \+ 1;/, generated)
    assert_match(/__mt_frame->local_task\.release\(__mt_frame->local_task\.frame\);/, generated)
  end

  def test_generate_c_preserves_task_local_await_after_exhaustive_match
    source = <<~MT

# module demo.async_match_wait

import std.async as aio

async function main() -> int:
    let task = aio.sleep(1)
    let tick = await aio.sleep(1)
    match tick:
        0:
            pass
        _:
            pass
    return await task + 1

    MT

    generated = generate_c_from_source(source)

    assert_match(/switch \(__mt_frame->local_tick\)/, generated)
    assert_match(/if \(!__mt_frame->local_task\.ready\(__mt_frame->local_task\.frame\)\)/, generated)
    assert_match(/__mt_frame->local___mt_async_tmp_\d+ = __mt_frame->local_task\.take_result\(__mt_frame->local_task\.frame\);/, generated)
  end

  def test_generate_c_for_async_proc_param_lifecycle
    source = <<~MT

# module demo.async_proc_lifecycle

async function run(callback: proc(value: int) -> int) -> int:
    return callback(1)

    MT

    generated = generate_c_from_source(source)

    # Constructor must retain the proc param so the frame outlives the caller's copy.
    assert_match(/param_callback\.retain\(__mt_frame->param_callback\.env\)/, generated)
    # Release function must null-guard release the proc param field before freeing the frame.
    assert_match(/if \(__mt_frame->param_callback\.invoke\)/, generated)
    assert_match(/__mt_frame->param_callback\.release\(__mt_frame->param_callback\.env\)/, generated)
  end

  def test_generate_c_for_async_proc_local_lifecycle
    source = <<~MT

# module demo.async_proc_local

async function run(offset: int) -> int:
    let callback = proc(value: int) -> int:
        return value + offset
    return callback(1)

    MT

    generated = generate_c_from_source(source)

    # Local proc stored in frame; no extra retain (frame owns freshly-allocated env).
    # Release function must null-guard release the local proc field before freeing the frame.
    assert_match(/if \(__mt_frame->local_callback\.invoke\)/, generated)
    assert_match(/__mt_frame->local_callback\.release\(__mt_frame->local_callback\.env\)/, generated)
  end

  def test_generate_c_for_async_variant_payload_match
    source = <<~MT

# module demo.async_variant_payload_codegen



async function helper() -> Result[int, int]:
    return Result[int, int].success(value= 7)

async function main() -> int:
    let result = await helper()
    match result:
        Result.success as payload:
            let value = payload.value
            return value
        Result.failure as payload:
            let error = payload.error
            return error
    return 9
    MT

    generated = generate_c_from_source(source)

    assert_match(/Result_int_int_success payload = .*\.data\.success;/, generated)
    assert_match(/Result_int_int_failure .*\.data\.failure;/, generated)
  end

  def test_run_program_for_async_status_result
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

# module demo.async_status_codegen



async function helper() -> Result[int, int]:
    return Result[int, int].success(value= 7)

async function main() -> int:
    let result = await helper()
    match result:
        Result.success as payload:
            let value = payload.value
            return value
        Result.failure as payload:
            let error = payload.error
            return error
    return 9
    MT

    result = run_program_from_source(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_generate_c_for_async_main_uses_std_async_wait
    source = <<~MT
      # module demo.async_main_codegen

      import std.async as aio

      async function main(args: span[str]) -> int:
          return await aio.sleep(1) + int<-args.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t main\(int32_t argc, char \*\*argv\)/, generated)
    assert_match(/__mt_async_main_arg_1/, generated)
    assert_match(/std_async_wait_int\(__mt_async_main_root\)/, generated)
    refute_match(/async main runtime loop failed/, generated)
  end

  def test_generate_c_for_async_void_main_uses_std_async_run
    source = <<~MT
      # module demo.async_main_void_codegen

      import std.async as aio

      async function main() -> void:
          await aio.sleep(1)
          return
    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t main\(void\)/, generated)
    assert_match(/std_async_run\(__mt_async_main_root\)/, generated)
    refute_match(/async main runtime loop failed/, generated)
  end

end
