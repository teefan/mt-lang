# frozen_string_literal: true

require "fileutils"
require "tempfile"
require_relative "../test_helper"

class MilkTeaCodegenTest < Minitest::Test
  def test_generate_c_for_demo_emits_structs_functions_and_imported_headers
    program = MilkTea::ModuleLoader.check_program(demo_path)
    generated = MilkTea::Codegen.generate_c(program)

    assert_match(/#include <stdbool\.h>/, generated)
    assert_match(/#include <stdint\.h>/, generated)
    assert_match(/#include "raylib\.h"/, generated)
    assert_match(/typedef struct demo_bouncing_ball_Ball/, generated)
    assert_match(/static void demo_bouncing_ball_Ball_update\(demo_bouncing_ball_Ball \*this, float dt\)/, generated)
    assert_match(/demo_bouncing_ball_Ball_update\(&ball, dt\);/, generated)
    assert_match(/int32_t main\(void\)/, generated)
    assert_equal 1, generated.scan("CloseWindow();").length
  end

    def test_generate_c_for_local_enums_flags_and_unions
      source = [
        "module demo.codegen_surface",
        "",
        "enum State: i32",
        "    idle = 0",
        "    running = 1",
        "",
        "flags WindowFlags: u32",
        "    visible = 1 << 0",
        "    resizable = 1 << 1",
        "",
        "union Payload:",
        "    count: i32",
        "    enabled: bool",
        "",
        "const DEFAULT_STATE: State = State.idle",
        "const DEFAULT_FLAGS: WindowFlags = WindowFlags.visible | WindowFlags.resizable",
        "",
        "def pick_state(active: bool) -> State:",
        "    if active:",
        "        return State.running",
        "    return DEFAULT_STATE",
        "",
        "def main() -> i32:",
        "    let current = pick_state(true)",
        "    if current == State.running:",
        "        return 1",
        "    return 0",
        "",
      ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef int32_t demo_codegen_surface_State;/, generated)
    assert_match(/demo_codegen_surface_State_idle = 0/, generated)
    assert_match(/demo_codegen_surface_State_running = 1/, generated)
    assert_match(/typedef uint32_t demo_codegen_surface_WindowFlags;/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_visible = 1 << 0/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_resizable = 1 << 1/, generated)
    assert_match(/typedef union demo_codegen_surface_Payload/, generated)
    assert_match(/static const demo_codegen_surface_State demo_codegen_surface_DEFAULT_STATE = demo_codegen_surface_State_idle;/, generated)
    assert_match(/static const demo_codegen_surface_WindowFlags demo_codegen_surface_DEFAULT_FLAGS = demo_codegen_surface_WindowFlags_visible \| demo_codegen_surface_WindowFlags_resizable;/, generated)
    assert_match(/if \(current == demo_codegen_surface_State_running\)/, generated)
    assert_match(/return 1;/, generated)
    end

  def test_generate_c_includes_imported_ordinary_module_definitions
    Dir.mktmpdir("milk-tea-codegen-imports") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      FileUtils.mkdir_p(File.join(dir, "demo"))

      File.write(File.join(dir, "std", "math.mt"), [
        "module std.math",
        "",
        "pub const TEN: i32 = 10",
        "pub const UNUSED: i32 = 99",
        "",
        "pub def clamp[T](value: T, min_value: T, max_value: T) -> T:",
        "    if value < min_value:",
        "        return min_value",
        "    elif value > max_value:",
        "        return max_value",
        "    return value",
        "",
      ].join("\n"))

      root_path = File.join(dir, "demo", "main.mt")
      File.write(root_path, [
        "module demo.main",
        "",
        "import std.math as math",
        "",
        "def main() -> i32:",
        "    return math.clamp(42, 0, math.TEN)",
        "",
      ].join("\n"))

      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(root_path)
      generated = MilkTea::Codegen.generate_c(program)

      assert_match(/static const int32_t std_math_TEN = 10;/, generated)
      refute_match(/static const int32_t std_math_UNUSED = 99;/, generated)
      assert_match(/static int32_t std_math_clamp_i32\(int32_t value, int32_t min_value, int32_t max_value\)/, generated)
      assert_match(/return std_math_clamp_i32\(42, 0, std_math_TEN\);/, generated)
    end
  end

  def test_generate_c_for_unsafe_pointer_cast_and_arithmetic
    source = [
      "module demo.pointer_surface",
      "",
      "extern def allocate(size: usize) -> ptr[void]",
      "extern def release(memory: ptr[void]) -> void",
      "",
      "def main() -> i32:",
      "    let memory = allocate(16)",
      "    unsafe:",
      "        let advanced = ptr[byte]<-memory + 4",
      "    release(memory)",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/uint8_t \*advanced = \(\(\(uint8_t\*\) memory\)\) \+ 4;/, generated)
    assert_match(/release\(memory\);/, generated)
  end

  def test_generate_c_for_span_construction_and_field_access
    source = [
      "module demo.span_surface",
      "",
      "def first(items: span[i32]) -> i32:",
      "    if items.len == 0:",
      "        return 0",
      "    unsafe:",
      "        return read(items.data)",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = span[i32](data = ptr_of(ref_of(value)), len = 1)",
      "    return first(items)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_span_i32/, generated)
    assert_match(/int32_t \*data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static int32_t demo_span_surface_first\(mt_span_i32 items\)/, generated)
    assert_match(/if \(items\.len == 0\)/, generated)
    assert_match(/return \*items\.data;/, generated)
    assert_match(/mt_span_i32 items = \(mt_span_i32\)\{ \.data = &value, \.len = 1 \};/, generated)
  end

  def test_generate_c_for_async_methods
    source = <<~MT
      module demo.async_methods_codegen

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

    generated = generate_c_from_program_source(source)

    assert_match(/demo_async_methods_codegen_Counter_bump__frame/, generated)
    assert_match(/demo_async_methods_codegen_Counter_read__frame/, generated)
    assert_match(/demo_async_methods_codegen_Counter_bump\(&__mt_frame->local_counter\)/, generated)
    assert_match(/demo_async_methods_codegen_Counter_read\(__mt_frame->local_counter\)/, generated)
  end

  def test_generate_c_for_generic_methods
    source = <<~MT
      module demo.generic_methods_codegen

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

    generated = generate_c_from_program_source(source)

    assert_match(/demo_generic_methods_codegen_Box_echo_i32/, generated)
    assert_match(/demo_generic_methods_codegen_Box_make_i32/, generated)
    assert_match(/demo_generic_methods_codegen_Box_echo_i32\(box, 3\)/, generated)
    assert_match(/demo_generic_methods_codegen_Box_make_i32\(4\)/, generated)
  end

  def test_generate_c_for_async_with_control_flow
    source = <<~MT
      module demo.async_flow_codegen

      import std.async as async

      async def sum_range(limit: i32) -> i32:
          var total: i32 = 0
          for i in range(0, limit):
              total += i
          return total

      async def clamp_sum(limit: i32) -> i32:
          let total = await sum_range(limit)
          if total > 100:
              return 100
          elif total < 0:
              return 0
          else:
              return total

      async def main() -> i32:
          return await clamp_sum(20)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_async_flow_codegen_sum_range__frame/, generated)
    assert_match(/demo_async_flow_codegen_clamp_sum__frame/, generated)
    assert_match(/for\s*\(/, generated)
    assert_match(/total\s*\+=/, generated)
  end

    def test_generate_c_for_await_in_if_body
      source = <<~MT
        module demo.await_in_if

        import std.async as async

        async def child() -> i32:
            return 42

        async def parent() -> i32:
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
        module demo.await_in_while

        import std.async as async

        async def tick() -> i32:
            return 1

        async def accumulate(limit: i32) -> i32:
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

    def test_generate_c_for_await_in_if_condition
      source = <<~MT
        module demo.await_in_if_condition

        import std.async as async

        async def ready() -> bool:
            return true

        async def parent() -> i32:
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
        module demo.await_short_circuit

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

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_short_circuit_parent__frame/, generated)
      assert_match(/resume_state_1:/, generated)
      assert_match(/resume_state_2:/, generated)
    end

    def test_generate_c_for_await_in_if_expression
      source = <<~MT
        module demo.await_if_expr

        import std.async as async

        async def child() -> i32:
            return 7

        async def parent(flag: bool) -> i32:
            return if flag then await child() else 0
      MT

      generated = generate_c_from_program_source(source)

      assert_match(/demo_await_if_expr_parent__frame/, generated)
      assert_match(/resume_state_1:/, generated)
      assert_match(/if\s*\(/, generated)
    end

  def test_generate_c_for_foreign_defs_with_out_and_automatic_cstr_temps
    source = <<~MT
      module demo.main

      import std.raylib as rl

      def main(path: str, data: span[u8]) -> i32:
          var data_size = 0
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

            extern def LoadFileData(file_name: cstr, data_size: ptr[i32]) -> ptr[u8]?
            extern def SaveFileData(file_name: cstr, data: ptr[u8], bytes: i32) -> bool
      MT
      "std/raylib.mt" => <<~MT,
        module std.raylib

        import std.c.raylib as c

        pub foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData
        pub foreign def save_file_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveFileData(file_name, data.data, i32<-data.len)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/std_mem_arena_Arena_mark\(/, generated)
    refute_match(/std_mem_arena_Arena_reset\(/, generated)
    assert_match(/mt_foreign_str_to_cstr_temp/, generated)
    assert_match(/mt_free_foreign_cstr_temp/, generated)
    assert_match(/LoadFileData\(/, generated)
    assert_match(/&data_size/, generated)
    assert_match(/SaveFileData\(/, generated)
    assert_match(/SaveFileData\(__mt_foreign_arg_\d+, data\.data, \(\(int32_t\) data\.len\)\);|SaveFileData\(__mt_foreign_arg_\d+, data\.data, \(int32_t\) data\.len\);/, generated)
  end

  def test_generate_c_for_cleanup_bearing_foreign_results_without_intermediate_result_temps
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main(path: str) -> i32:
          let first = sample.load(path)
          var second = 0
          second = sample.load(path)
          return first + second
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Load(path: cstr) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def load(path: str as cstr) -> i32 = c.Load
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_result_\d+/, generated)
    assert_match(/int32_t first = Load\(__mt_foreign_arg_\d+\);/, generated)
    assert_match(/second = Load\(__mt_foreign_arg_\d+\);/, generated)
    assert_match(/mt_free_foreign_cstr_temp\(__mt_foreign_arg_\d+\);/, generated)
  end

  def test_generate_c_for_std_fmt_string_format_literals
    source = <<~MT
      module demo.format_codegen

      import std.fmt as fmt
      import std.string as string

      def main(value: u8, delta: i16, ticks: u64, raw: cstr) -> i32:
          let text = fmt.string(f"value=\#{value} delta=\#{delta} ticks=\#{ticks} raw=\#{raw} ok=\#{true}")
          return i32<-text.count()
    MT

    generated = generate_c_from_source(source)

    assert_match(/static std_string_String demo_format_codegen__fmt_1\(/, generated)
    assert_match(/std_string_String text = demo_format_codegen__fmt_1\(\(\(uint32_t\) value\), \(\(int32_t\) delta\), ticks, raw, true\);/, generated)
    assert_match(/std_string_String_with_capacity\(29\)/, generated)
    assert_match(/std_fmt_append\(/, generated)
    assert_match(/std_fmt_append_u32\(/, generated)
    assert_match(/std_fmt_append_i32\(/, generated)
    assert_match(/std_fmt_append_u64\(/, generated)
    assert_match(/std_fmt_append_cstr\(/, generated)
    assert_match(/std_fmt_append_bool\(/, generated)
    refute_match(/std_fmt_append\(&text/, generated)
  end

  def test_generate_c_for_general_format_string_expressions
    source = <<~MT
      module demo.format_expr_codegen

      def sink(text: str) -> usize:
          return text.len

      def main(value: u8, delta: i16) -> i32:
          let text = f"value=\#{value} delta=\#{delta}"
          if sink(f"ok=\#{true}") == 0:
              return 1
          return i32<-text.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/static std_string_String demo_format_expr_codegen__fmt_1\(/, generated)
    assert_match(/std_string_String __mt_fmt_string_1 = demo_format_expr_codegen__fmt_1\(\(\(uint32_t\) value\), \(\(int32_t\) delta\)\);/, generated)
    assert_match(/mt_str text = std_string_String_as_str\(__mt_fmt_string_1\);/, generated)
    assert_match(/demo_format_expr_codegen_sink\(std_string_String_as_str\(__mt_fmt_string_2\)\)/, generated)
    assert_match(/std_string_String_release\(&__mt_fmt_string_2\);/, generated)
    assert_match(/std_string_String_release\(&__mt_fmt_string_1\);/, generated)
  end

  def test_generate_c_reuses_identical_format_string_helpers
    source = <<~MT
      module demo.format_dedup_codegen

      def first(value: u8) -> usize:
          let text = f"value=\#{value} ok=\#{true}"
          return text.len

      def second(value: u8) -> usize:
          let text = f"value=\#{value} ok=\#{true}"
          return text.len
    MT

    generated = generate_c_from_source(source)

    assert_match(/static std_string_String demo_format_dedup_codegen__fmt_1\(/, generated)
    refute_match(/demo_format_dedup_codegen__fmt_2\(/, generated)
    assert_match(/std_string_String __mt_fmt_string_1 = demo_format_dedup_codegen__fmt_1\(/, generated)
  end

  def test_rejects_returning_general_format_string_as_borrowed_text
    source = <<~MT
      module demo.format_expr_escape

      def main(value: i32) -> str:
          return f"value=\#{value}"
    MT

    error = assert_raises(MilkTea::LoweringError) do
      generate_c_from_source(source)
    end

    assert_match(/formatted string temporaries cannot be returned as borrowed text/, error.message)
  end

  def test_generate_c_for_cstr_backed_string_constants_without_foreign_temps
    source = <<~MT
      module demo.main

      import std.sample as sample

      const PATH: str = "demo.txt"

      def main() -> i32:
          return sample.load(PATH)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Load(path: cstr) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def load(path: str as cstr) -> i32 = c.Load
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_foreign_str_to_cstr_temp/, generated)
    refute_match(/mt_free_foreign_cstr_temp/, generated)
    assert_match(/return Load\(\(\(const char\*\) demo_main_PATH\.data\)\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_in_const_void_pointer
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          let value = 7
          sample.inspect(in value)
          sample.inspect(in (value + 1))
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/Inspect\(\(\(const void\*\) \(&value\)\)\);/, generated)
    assert_match(/int32_t __mt_foreign_in_\d+ = value \+ 1;/, generated)
    assert_match(/Inspect\(\(\(const void\*\) \(&__mt_foreign_in_\d+\)\)\);/, generated)
  end

  def test_generate_c_for_local_const_ptr_typed_binding
    source = <<~MT
      module demo.main

      def main() -> void:
          let value = 7
          let pointer: const_ptr[i32] = const_ptr_of(value)
          let copy: const_ptr[i32] = pointer
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/const int32_t\* pointer = &value;/, generated)
    assert_match(/const int32_t\* copy = pointer;/, generated)
  end

  def test_generate_c_escapes_local_names_that_match_c_keywords
    source = <<~MT
      module demo.main

      def main() -> i32:
          let double = 7
          return double + 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/int32_t double_ = 7;/, generated)
    assert_match(/return double_ \+ 1;/, generated)
  end

  def test_generate_c_for_deferred_literal_return_without_spill_temp
    source = <<~MT
      module demo.main

      import std.raylib as rl

      def main() -> i32:
          rl.init_window(800, 450, "Demo")
          defer rl.close_window()
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/CloseWindow\(\);\s+(?:#[^\n]*\n\s+)?return 0;/m, generated)
    refute_match(/__mt_return_value_\d+/, generated)
  end

  def test_generate_c_for_foreign_defs_with_string_literal_without_using_scratch
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/Arena_mark\(/, generated)
    refute_match(/Arena_reset\(/, generated)
    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/InitWindow\(800, 450, "Demo"\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_span_str_to_span_cstr_boundary
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> i32:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 1
          return sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[cstr], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[str] as span[cstr], inout active: i32) -> i32 = c.UseNames(names.data, i32<-names.len, active)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    refute_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/const char\* __mt_foreign_cstr_items_\d+\[3\] = \{ \(\(const char\*\) labels\[0\]\.data\), \(\(const char\*\) labels\[1\]\.data\), \(\(const char\*\) labels\[2\]\.data\) \};/, generated)
    assert_match(/__mt_foreign_arg_\d+\.data/, generated)
    assert_match(/\(\(int32_t\) __mt_foreign_arg_\d+\.len\)|\(int32_t\) __mt_foreign_arg_\d+\.len/, generated)
  end

  def test_generate_c_for_foreign_defs_with_span_str_to_span_ptr_char_boundary
    source = <<~MT
      module demo.main

      import std.sample as sample

      def middle() -> str:
          return "Options"

      def main() -> i32:
          var labels = array[str, 3]("Play", middle(), "Quit")
          var active = 1
          return sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[ptr[char]], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[str] as span[ptr[char]], inout active: i32) -> i32 = c.UseNames(names.data, i32<-names.len, active)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/__mt_foreign_arg_\d+\.data/, generated)
    assert_match(/\(\(int32_t\) __mt_foreign_arg_\d+\.len\)|\(int32_t\) __mt_foreign_arg_\d+\.len/, generated)
  end

  def test_generate_c_for_ignored_foreign_result_with_span_str_temp_marshalling
    source = <<~MT
      module demo.main

      import std.sample as sample

      def middle() -> str:
          return "Options"

      def main() -> i32:
          var labels = array[str, 3]("Play", middle(), "Quit")
          var active = 1
          sample.use_names(labels, inout active)
          return active
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[ptr[char]], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[str] as span[ptr[char]], inout active: i32) -> i32 = c.UseNames(names.data, i32<-names.len, active)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    refute_match(/__mt_foreign_result_\d+/, generated)
  end

  def test_generate_c_for_nested_foreign_defs_in_inline_contexts
    source = <<~MT
      module demo.main

      import std.sample as sample

      def middle() -> str:
          return "34"

      def keep(value: i32) -> i32:
          return value

      def main() -> i32:
          var labels = array[str, 3]("12", middle(), "56")
          let counted = keep(sample.count_names(labels))
          let doubled = keep(sample.pair_sum(1 + 2))
          return counted + doubled
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

        pub foreign def count_names(names: span[str] as span[ptr[char]]) -> i32 = c.CountNames(names.data, i32<-names.len)
        pub foreign def pair_sum(value: i32) -> i32 = c.PairSum(value, value)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    refute_match(/__mt_foreign_expr_\d+/, generated)
    refute_match(/int32_t __mt_foreign_arg_\d+ = 1 \+ 2;/, generated)
    assert_match(/int32_t doubled = demo_main_keep\(PairSum\(1 \+ 2, 1 \+ 2\)\);/, generated)
    assert_match(/CountNames\(/, generated)
    assert_match(/PairSum\(/, generated)
  end

  def test_rejects_codegen_for_foreign_defs_with_str_to_ptr_char_boundary
    source = <<~MT
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
      generate_c_from_program_source(source, imported_sources)
    end

    assert_match(/cannot map str as ptr\[char\]/, error.message)
  end

  def test_generate_c_for_foreign_defs_with_span_cstr_to_span_ptr_char_without_scratch
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> i32:
          var labels = array[cstr, 3]("Play", "Options", "Quit")
          var active = 1
          return sample.use_names(labels, inout active)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def UseNames(names: ptr[ptr[char]], count: i32, active: ptr[i32]) -> i32
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def use_names(names: span[cstr] as span[ptr[char]], inout active: i32) -> i32 = c.UseNames(names.data, i32<-names.len, active)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/typedef struct mt_span_cstr \{/, generated)
    assert_match(/const char\* labels\[3\] = \{ "Play", "Options", "Quit" \};/, generated)
    refute_match(/std_mem_arena_Arena_to_char_ptrs\(/, generated)
    refute_match(/std_mem_arena_Arena_to_cstrs\(/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/&labels\[0\]/, generated)
    assert_match(/&active/, generated)
  end

  def test_generate_c_for_contextual_string_literals_as_cstr
    source = <<~MT
      module demo.literal_cstr

      extern def set_text(value: cstr) -> void

      def main() -> cstr:
          let title: cstr = "hello"
          set_text("world")
          return title
    MT

    generated = generate_c_from_source(source)

    assert_match(/const char\* title = "hello";/, generated)
    assert_match(/set_text\("world"\);/, generated)
    assert_match(/return title;/, generated)
  end

  def test_generate_c_for_foreign_defs_with_inout_uses_minimal_address_of
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          var camera = sample.Camera(id = 1)
          sample.update_camera(inout camera, sample.CameraMode.CAMERA_FREE)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            struct Camera:
                id: i32

            enum CameraMode: i32
                CAMERA_FREE = 1

            extern def UpdateCamera(camera: ptr[Camera], mode: CameraMode) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub type Camera = c.Camera
        pub type CameraMode = c.CameraMode

        pub foreign def update_camera(inout camera: Camera, mode: CameraMode) -> void = c.UpdateCamera
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/UpdateCamera\(&camera, CAMERA_FREE\);/, generated)
    refute_match(/UpdateCamera\(\(\([A-Za-z_][A-Za-z0-9_]*\*\) \(&camera\)\), CAMERA_FREE\);/, generated)
  end

  def test_generate_c_for_foreign_defs_without_temps_for_simple_statement_arguments
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main(center: f32) -> void:
          sample.draw_triangle(
              sample.Vector2(x = center, y = 80.0),
              sample.Vector2(x = center - 60.0, y = 150.0),
              sample.Vector2(x = center + 60.0, y = 150.0),
              sample.VIOLET,
          )
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            struct Vector2:
                x: f32
                y: f32

            struct Color:
                r: u8
                g: u8
                b: u8
                a: u8

            const VIOLET: Color = Color(r = 200, g = 122, b = 255, a = 255)

            extern def DrawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, color: Color) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub type Vector2 = c.Vector2
        pub type Color = c.Color
        pub const VIOLET: Color = c.VIOLET

        pub foreign def draw_triangle(v1: Vector2, v2: Vector2, v3: Vector2, color: Color) -> void = c.DrawTriangle
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/DrawTriangle\(\(Vector2\)\{ \.x = center, \.y = 80\.0f \}, \(Vector2\)\{ \.x = center - 60\.0f, \.y = 150\.0f \}, \(Vector2\)\{ \.x = center \+ 60\.0f, \.y = 150\.0f \}, std_sample_VIOLET\);/, generated)
  end

  def test_generate_c_for_checked_span_index_foreign_arguments_without_foreign_arg_temps
    source = <<~MT
      module demo.main

      import std.sample as sample

      struct Bunny:
          x: i32
          y: i32
          color: i32

      def main(items: span[Bunny], count: i32) -> void:
          for index in range(0, count):
              sample.draw(items[index].x, items[index].y, items[index].color)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            extern def Draw(x: i32, y: i32, color: i32) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub foreign def draw(x: i32, y: i32, color: i32) -> void = c.Draw
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    refute_match(/int32_t index = __mt_for_index_\d+;/, generated)
    assert_match(/for \(int32_t index = 0; index < __mt_for_stop_\d+; index \+= 1\)/, generated)
    assert_match(/demo_main_Bunny \*__mt_checked_index_ptr_\d+ = mt_checked_span_index_span_demo_main_Bunny\(items, index\);/, generated)
    assert_match(/Draw\(__mt_checked_index_ptr_\d+->x, __mt_checked_index_ptr_\d+->y, __mt_checked_index_ptr_\d+->color\);/, generated)
  end

  def test_generate_c_for_nested_foreign_calls_with_imported_arguments
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main() -> void:
          sample.use_color(sample.fade(sample.RED, 0.5))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            struct Color:
                r: u8
                g: u8
                b: u8
                a: u8

            const RED: Color = Color(r = 255, g = 0, b = 0, a = 255)

            extern def Fade(color: Color, alpha: f32) -> Color
            extern def UseColor(color: Color) -> void
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub type Color = c.Color
        pub const RED: Color = c.RED

        pub foreign def fade(color: Color, alpha: f32) -> Color = c.Fade
        pub foreign def use_color(color: Color) -> void = c.UseColor
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/UseColor\(Fade\(std_sample_RED, 0\.5f\)\);/, generated)
  end

  def test_generate_c_for_foreign_text_calls_without_numbered_argument_temps
    source = <<~MT
      module demo.main

      import std.sample as sample

      def main(area: i32) -> void:
          let label = "COLLISION!"
          sample.draw_text(label, sample.screen_width() / 2 - sample.measure_text(label, 20) / 2, 10, 20, sample.BLACK)
          sample.draw_text(sample.text_format_i32("Collision Area: %i", area), sample.screen_width() / 2 - 100, 20, 20, sample.BLACK)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        extern module std.c.sample:
            const BLACK: i32 = 0

            extern def DrawText(text: cstr, pos_x: i32, pos_y: i32, font_size: i32, color: i32) -> void
            extern def MeasureText(text: cstr, font_size: i32) -> i32
            extern def GetScreenWidth() -> i32
            extern def TextFormat(format: cstr, value: i32) -> cstr
      MT
      "std/sample.mt" => <<~MT,
        module std.sample

        import std.c.sample as c

        pub const BLACK: i32 = c.BLACK

        pub foreign def draw_text(text: str as cstr, pos_x: i32, pos_y: i32, font_size: i32, color: i32) -> void = c.DrawText
        pub foreign def measure_text(text: str as cstr, font_size: i32) -> i32 = c.MeasureText
        pub foreign def screen_width() -> i32 = c.GetScreenWidth
        pub foreign def text_format_i32(format: str as cstr, value: i32) -> cstr = c.TextFormat(format, value)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/DrawText\(\(\(const char\*\) label\.data\), \(GetScreenWidth\(\) \/ 2\) - \(MeasureText\(\(\(const char\*\) label\.data\), 20\) \/ 2\), 10, 20, std_sample_BLACK\);/, generated)
    assert_match(/DrawText\(TextFormat\("Collision Area: %i", area\), \(GetScreenWidth\(\) \/ 2\) - 100, 20, 20, std_sample_BLACK\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_identity_pointer_projections
    source = <<~MT
      module demo.main

      import std.mem as mem

      def first_byte() -> byte:
          unsafe:
              return mem.allocate_bytes(16)[0]

      def main(buffer: ptr[char]) -> byte:
          mem.release_bytes(mem.allocate_bytes(8))
          mem.set_label(buffer)
          return first_byte()
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        extern module std.c.mem:
            include "mem.h"

            extern def AllocateBytes(size: usize) -> ptr[void]
            extern def ReleaseBytes(memory: ptr[void]) -> void
            extern def SetLabel(label: cstr) -> void
      MT
      "std/mem.mt" => <<~MT,
        module std.mem

        import std.c.mem as c

        pub foreign def allocate_bytes(size: usize) -> ptr[byte] = c.AllocateBytes
        pub foreign def release_bytes(memory: ptr[byte]) -> void = c.ReleaseBytes
        pub foreign def set_label(label: ptr[char]) -> void = c.SetLabel
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/return \(\(\(uint8_t\*\) AllocateBytes\(16\)\)\)\[0\];/, generated)
    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/ReleaseBytes\(\(\(uint8_t\*\) AllocateBytes\(8\)\)\);/, generated)
    assert_match(/SetLabel\(buffer\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_external_struct_boundary_reinterpret
    source = <<~MT
      module demo.main

      import std.shared as shared
      import std.sample as sample

      def main() -> shared.Matrix:
          var matrix = sample.get_matrix()
          sample.set_matrix(shared.IDENTITY)
          sample.set_matrix_ptr(ptr_of(ref_of(matrix)))
          return matrix
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

            extern def SetMatrix(matrix: Matrix) -> void
            extern def SetMatrixPtr(matrix: ptr[Matrix]) -> void
            extern def GetMatrix() -> Matrix
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
        pub foreign def set_matrix_ptr(matrix: ptr[shared.Matrix] as ptr[c.Matrix]) -> void = c.SetMatrixPtr
        pub foreign def get_matrix() -> shared.Matrix = c.GetMatrix
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_reinterpret_std_c_shared_Matrix_from_std_c_sample_Matrix/, generated)
    refute_match(/mt_reinterpret_std_c_sample_Matrix_from_std_c_shared_Matrix/, generated)
    assert_match(/SetMatrix\(std_shared_IDENTITY\);/, generated)
    assert_match(/SetMatrixPtr\(&matrix\);/, generated)
    assert_match(/Matrix matrix = GetMatrix\(\);/, generated)
    assert_match(/return matrix;/, generated)
  end

  def test_generate_c_for_foreign_defs_with_opaque_handle_projections
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/typedef struct std_window_Window std_window_Window;/, generated)
    assert_match(/std_window_Window\* window = CreateWindow\(\);/, generated)
    assert_match(/DestroyWindow\(window\);/, generated)
  end

  def test_generate_c_for_owned_foreign_release_calls
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/std_window_Window\* window = CreateWindow\(\);/, generated)
    assert_match(/DestroyWindow\(window\);/, generated)
    assert_match(/window = NULL;/, generated)
    assert_match(/if \(window == NULL\)/, generated)
  end

  def test_generate_c_for_safe_span_indexing_and_element_assignment
    source = [
      "module demo.span_index_surface",
      "",
      "def bump(items: span[i32]) -> i32:",
      "    let first = items[0]",
      "    items[0] = first + 2",
      "    return items[0]",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = span[i32](data = ptr_of(ref_of(value)), len = 1)",
      "    return bump(items)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static inline int32_t \*mt_checked_span_index_span_i32\(mt_span_i32 span, uintptr_t index\)/, generated)
    assert_match(/if \(index >= span\.len\) mt_panic\("span index out of bounds"\);/, generated)
    assert_match(/int32_t first = \(\*mt_checked_span_index_span_i32\(items, 0\)\);/, generated)
    assert_match(/\(\*mt_checked_span_index_span_i32\(items, 0\)\) = first \+ 2;/, generated)
    assert_match(/return \(\*mt_checked_span_index_span_i32\(items, 0\)\);/, generated)
  end

  def test_generate_c_for_mixed_numeric_binary_operations_inserts_explicit_casts
    source = [
      "module demo.numeric_codegen",
      "",
      "def main() -> i32:",
      "    let sum = 1 + 2.5",
      "    if 3 < 3.5 and sum > 3.0:",
      "        return 1",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/double sum = \(\(\(double\) 1\)\) \+ 2\.5;/, generated)
    assert_match(/if \(\(\(\(\(double\) 3\)\) < 3\.5\) && \(sum > 3\.0\)\)/, generated)
  end

  def test_generate_c_for_prefix_cast_syntax
    source = [
      "module demo.prefix_cast_codegen",
      "",
      "def main(value: f32, a: i32, b: i32) -> i32:",
      "    let left = i32<-value",
      "    let right = u8<-(a - b)",
      "    return left + i32<-right",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/int32_t left = \(\(int32_t\) value\);/, generated)
    assert_match(/uint8_t right = \(\(uint8_t\) \(a - b\)\);/, generated)
  end

  def test_generate_c_for_if_expressions
    source = [
      "module demo.if_expr_codegen",
      "",
      "def main(ready: bool) -> i32:",
      "    let score = if ready then 1 else 0",
      "    return if ready then score else score + 1",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/int32_t score = ready \? 1 : 0;/, generated)
    assert_match(/return ready \? score : \(score \+ 1\);/, generated)
  end

  def test_generate_c_for_variadic_extern_calls
    source = [
      "module demo.variadic_codegen",
      "",
      "extern def printf(format: cstr, ...) -> i32",
      "",
      "def main() -> i32:",
      "    return printf(c\"value=%d %s\\n\", 7, c\"ok\")",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/return demo_variadic_codegen_printf\("value=%d %s\\n", 7, "ok"\);/, generated)
  end

  def test_generate_c_for_contextual_numeric_coercion_at_external_boundaries
    generated = generate_c_from_program_source(
      <<~MT,
        module demo.external_numeric_codegen

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

    assert_match(/\.r = \(\(uint8_t\) channel\)/, generated)
    assert_match(/color\.g = \(\(uint8_t\) channel\);/, generated)
    assert_match(/set_scale\(\(\(float\) channel\)\);/, generated)
  end

  def test_generate_c_for_contextual_integer_to_float_at_local_assignment_and_return_boundaries
    source = [
      "module demo.contextual_int_to_float_codegen",
      "",
      "struct Point:",
      "    x: f32",
      "",
      "def project(value: i32) -> f32:",
      "    var total: f32 = value",
      "    total = value + 1",
      "    var point = Point(x = 0.0)",
      "    point.x = value + 2",
      "    return value + 3",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/float total = \(\(float\) value\);/, generated)
    assert_match(/total = \(\(float\) \(value \+ 1\)\);/, generated)
    assert_match(/point\.x = \(\(float\) \(value \+ 2\)\);/, generated)
    assert_match(/return \(\(float\) \(value \+ 3\)\);/, generated)
  end

  def test_generate_c_for_generic_struct_instantiation_and_embedding
    source = [
      "module demo.generic_surface",
      "",
      "struct Slice[T]:",
      "    data: ptr[T]",
      "    len: usize",
      "",
      "struct Holder:",
      "    items: Slice[i32]",
      "",
      "def first(items: Slice[i32]) -> i32:",
      "    if items.len == 0:",
      "        return 0",
      "    unsafe:",
      "        return read(items.data)",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let holder = Holder(items = Slice[i32](data = ptr_of(ref_of(value)), len = 1))",
      "    return first(holder.items)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_generic_surface_Slice_i32 demo_generic_surface_Slice_i32;/, generated)
    assert_match(/typedef struct demo_generic_surface_Holder demo_generic_surface_Holder;/, generated)
    assert_match(/struct demo_generic_surface_Slice_i32 \{/, generated)
    assert_match(/int32_t \*data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/struct demo_generic_surface_Holder \{/, generated)
    assert_match(/demo_generic_surface_Slice_i32 items;/, generated)
    assert_match(/static int32_t demo_generic_surface_first\(demo_generic_surface_Slice_i32 items\)/, generated)
    assert_match(/demo_generic_surface_Holder holder = \(demo_generic_surface_Holder\)\{ \.items = \(demo_generic_surface_Slice_i32\)\{ \.data = &value, \.len = 1 \} \};/, generated)
  end

  def test_generate_c_for_generic_functions_with_inferred_type_arguments
    source = [
      "module demo.generic_functions",
      "",
      "struct Slice[T]:",
      "    data: ptr[T]",
      "    len: usize",
      "",
      "def head[T](items: Slice[T]) -> ptr[T]:",
      "    return items.data",
      "",
      "def min[T](a: T, b: T) -> T:",
      "    if a < b:",
      "        return a",
      "    return b",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = Slice[i32](data = ptr_of(ref_of(value)), len = 1)",
      "    let smallest = min(9, 4)",
      "    unsafe:",
      "        return read(head(items)) + smallest",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static int32_t \*demo_generic_functions_head_i32\(demo_generic_functions_Slice_i32 items\)/, generated)
    assert_match(/static int32_t demo_generic_functions_min_i32\(int32_t a, int32_t b\)/, generated)
    assert_match(/int32_t smallest = demo_generic_functions_min_i32\(9, 4\);/, generated)
    assert_match(/return \(\*demo_generic_functions_head_i32\(items\)\) \+ smallest;/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_type_arguments_and_layout_queries
    source = [
      "module demo.generic_layout",
      "",
      "def bytes_for[T](count: usize) -> usize:",
      "    return count * sizeof(T)",
      "",
      "def main() -> i32:",
      "    let total = bytes_for[i32](4)",
      "    return i32<-total",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_layout_bytes_for_i32\(uintptr_t count\)/, generated)
    assert_match(/return count \* sizeof\(int32_t\);/, generated)
    assert_match(/uintptr_t total = demo_generic_layout_bytes_for_i32\(4\);/, generated)
  end

  def test_generate_c_for_async_await_of_task_locals_without_redundant_await_slots
    source = [
      "module demo.async_clean",
      "",
      "import std.async as async",
      "",
      "async def child() -> i32:",
      "    let task = async.sleep(1)",
      "    return await task + 1",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/mt_task_i32 local_task;/, generated)
    refute_match(/mt_task_i32 await_0;/, generated)
    refute_match(/__mt_frame->await_0 = __mt_frame->local_task;/, generated)
    assert_match(/if \(!__mt_frame->local_task\.ready\(__mt_frame->local_task\.frame\)\)/, generated)
    assert_match(/__mt_frame->local___mt_async_tmp_1 = __mt_frame->local_task\.take_result\(__mt_frame->local_task\.frame\);/, generated)
    assert_match(/__mt_frame->result = __mt_frame->local___mt_async_tmp_1 \+ 1;/, generated)
    assert_match(/__mt_frame->local_task\.release\(__mt_frame->local_task\.frame\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_literal_type_arguments
    source = [
      "module demo.generic_builder",
      "",
      "def capacity_of[N](buffer: str_builder[N]) -> usize:",
      "    return buffer.capacity()",
      "",
      "def main() -> i32:",
      "    var buffer: str_builder[32]",
      "    return i32<-(capacity_of(buffer) + capacity_of(buffer))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_capacity_of_32\(mt_str_builder_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(\(int32_t\) \(demo_generic_builder_capacity_of_32\(buffer\) \+ demo_generic_builder_capacity_of_32\(buffer\)\)\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_literal_type_arguments
    source = [
      "module demo.generic_builder_explicit",
      "",
      "def capacity_of[N](buffer: str_builder[N]) -> usize:",
      "    return buffer.capacity()",
      "",
      "def main() -> i32:",
      "    var buffer: str_builder[32]",
      "    return i32<-capacity_of[32](buffer)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_explicit_capacity_of_32\(mt_str_builder_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(\(int32_t\) demo_generic_builder_explicit_capacity_of_32\(buffer\)\);/, generated)
  end

  def test_generate_c_for_generic_functions_with_explicit_named_const_type_arguments
    source = [
      "module demo.generic_builder_named_const",
      "",
      "const BASE: i32 = 28",
      "const CAPACITY: i32 = BASE + 4",
      "",
      "def capacity_of[N](buffer: str_builder[N]) -> usize:",
      "    return buffer.capacity()",
      "",
      "def main() -> i32:",
      "    var buffer: str_builder[CAPACITY]",
      "    return i32<-capacity_of[CAPACITY](buffer)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_builder_named_const_capacity_of_32\(mt_str_builder_32 buffer\)/, generated)
    assert_match(/return 32;/, generated)
    assert_match(/return \(\(int32_t\) demo_generic_builder_named_const_capacity_of_32\(buffer\)\);/, generated)
  end

  def test_generate_c_for_result_construction_from_expected_context
    source = [
      "module demo.result_surface",
      "",
      "enum LoadError: u8",
      "    invalid_format = 1",
      "",
      "def load(available: bool) -> Result[i32, LoadError]:",
      "    if available:",
      "        return ok(7)",
      "    return err(LoadError.invalid_format)",
      "",
      "def main() -> i32:",
      "    let loaded = load(false)",
      "    if loaded.is_ok:",
      "        return loaded.value",
      "    if loaded.error == LoadError.invalid_format:",
      "        return 1",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_result_i32_demo_result_surface_LoadError mt_result_i32_demo_result_surface_LoadError;/, generated)
    assert_match(/struct mt_result_i32_demo_result_surface_LoadError \{/, generated)
    assert_match(/bool is_ok;/, generated)
    assert_match(/int32_t value;/, generated)
    assert_match(/demo_result_surface_LoadError error;/, generated)
    assert_match(/return \(mt_result_i32_demo_result_surface_LoadError\)\{ \.is_ok = true, \.value = 7 \};/, generated)
    assert_match(/return \(mt_result_i32_demo_result_surface_LoadError\)\{ \.is_ok = false, \.error = demo_result_surface_LoadError_invalid_format \};/, generated)
  end

  def test_generate_c_for_builtin_panic_helper
    source = [
      "module demo.panic_surface",
      "",
      "def main() -> i32:",
      "    panic(\"bad state\")",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/#include <stdio\.h>/, generated)
    assert_match(/#include <stdlib\.h>/, generated)
    refute_match(/static void mt_panic\(const char\* message\)/, generated)
    assert_match(/static void mt_panic_str\(mt_str message\)/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/abort\(\);/, generated)
    assert_match(/mt_panic_str\(\(mt_str\)\{ \.data = "bad state", \.len = 9 \}\);/, generated)
  end

  def test_generate_c_dedupes_standard_runtime_headers_from_extern_imports
    source = [
      "module demo.include_surface",
      "",
      "import std.fs as fs",
      "import std.raylib as rl",
      "",
      "def main() -> i32:",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_equal 1, generated.scan('#include <stdio.h>').length
    assert_equal 1, generated.scan('#include <stdlib.h>').length
    refute_match(/#include "stdio\.h"/, generated)
    refute_match(/#include "stdlib\.h"/, generated)
    assert_match(/#include "raylib\.h"/, generated)
  end

  def test_generate_c_for_enum_match_statement_as_switch
    source = [
      "module demo.match_surface",
      "",
      "enum EventKind: u8",
      "    quit = 1",
      "    resize = 2",
      "",
      "def dispatch(kind: EventKind) -> i32:",
      "    match kind:",
      "        EventKind.quit:",
      "            return 0",
      "        EventKind.resize:",
      "            return 1",
      "",
      "def main() -> i32:",
      "    return dispatch(EventKind.resize)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/switch \(kind\) \{/, generated)
    assert_match(/case demo_match_surface_EventKind_quit: \{/, generated)
    assert_match(/case demo_match_surface_EventKind_resize: \{/, generated)
    assert_match(/return 0;/, generated)
    assert_match(/return 1;/, generated)
  end

  def test_generate_c_for_range_and_array_for_loops
    source = [
      "module demo.for_surface",
      "",
      "def sum(items: array[i32, 4]) -> i32:",
      "    var total = 0",
      "    for item in items:",
      "        total += item",
      "    for i in range(0, 4):",
      "        total += i",
      "    return total",
      "",
      "def main() -> i32:",
      "    return sum(array[i32, 4](1, 2, 3, 4))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/for \(uintptr_t __mt_for_index_\d+ = 0; __mt_for_index_\d+ < 4; __mt_for_index_\d+ \+= 1\)/, generated)
    assert_match(/int32_t item = __mt_for_items_\d+\[__mt_for_index_\d+\];/, generated)
    assert_match(/for \(int32_t i = 0; i < 4; i \+= 1\)/, generated)
    refute_match(/int32_t i = __mt_for_index_\d+;/, generated)
    refute_match(/int32_t __mt_for_stop_\d+ = 4;/, generated)
  end

  def test_generate_c_preserves_hoisted_stop_for_non_constant_range_bound
    source = [
      "module demo.for_stop_surface",
      "",
      "def main() -> i32:",
      "    var stop = 4",
      "    var total = 0",
      "    for i in range(0, stop):",
      "        stop += 1",
      "        total += i",
      "    return total + stop",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/int32_t __mt_for_stop_\d+ = stop;/, generated)
    assert_match(/for \(int32_t i = 0; i < __mt_for_stop_\d+; i \+= 1\)/, generated)
  end

  def test_generate_c_for_break_and_continue_inside_match_with_for_loop
    source = [
      "module demo.loop_control_surface",
      "",
      "enum Step: u8",
      "    skip = 1",
      "    keep = 2",
      "    stop = 3",
      "",
      "def add(target: ptr[i32], amount: i32) -> void:",
      "    unsafe:",
      "        read(target) += amount",
      "",
      "def main() -> i32:",
      "    var total = 0",
      "    for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):",
      "        defer add(ptr_of(ref_of(total)), 1)",
      "        match step:",
      "            Step.skip:",
      "                continue",
      "            Step.keep:",
      "                total += 10",
      "            Step.stop:",
      "                break",
      "    return total",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/for \(uintptr_t __mt_for_index_\d+ = 0; __mt_for_index_\d+ < 4; __mt_for_index_\d+ \+= 1\)/, generated)
    assert_match(/goto __mt_loop_continue_\d+;/, generated)
    assert_match(/goto __mt_loop_break_\d+;/, generated)
    assert_match(/__mt_loop_continue_\d+:;/, generated)
    assert_match(/__mt_loop_break_\d+:;/, generated)
  end

  def test_generate_c_omits_unused_loop_labels
    source = [
      "module demo.simple_loop_surface",
      "",
      "def main() -> i32:",
      "    var i = 0",
      "    while i < 3:",
      "        i += 1",
      "    return i",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/int32_t main\(void\) \{\s+(?:#[^\n]*\n\s+)?int32_t i = 0;\s+(?:#[^\n]*\n\s+)?while \(i < 3\) \{/m, generated)
    assert_match(/while \(i < 3\) \{/, generated)
    refute_match(/\n  \{\n    while \(i < 3\) \{/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
    refute_match(/__mt_loop_break_\d+:;/, generated)
    refute_match(/goto __mt_loop_(continue|break)_\d+;/, generated)
  end

  def test_generate_c_uses_structured_break_for_simple_loop_exit
    source = [
      "module demo.structured_break_surface",
      "",
      "def main() -> i32:",
      "    var total = 0",
      "    while total < 10:",
      "        total += 1",
      "        if total == 3:",
      "            break",
      "    return total",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/while \(total < 10\) \{/, generated)
    assert_match(/if \(total == 3\) \{\n      break;/, generated)
    refute_match(/goto __mt_loop_break_\d+;/, generated)
    refute_match(/__mt_loop_break_\d+:;/, generated)
  end

  def test_generate_c_uses_structured_continue_for_simple_while_loop
    source = [
      "module demo.structured_continue_surface",
      "",
      "def main() -> i32:",
      "    var total = 0",
      "    var i = 0",
      "    while i < 5:",
      "        i += 1",
      "        if i == 2:",
      "            continue",
      "        total += i",
      "    return total",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/if \(i == 2\) \{\n      continue;/, generated)
    refute_match(/goto __mt_loop_continue_\d+;/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
  end

  def test_generate_c_uses_structured_continue_for_simple_for_loop
    source = [
      "module demo.structured_for_continue_surface",
      "",
      "def main() -> i32:",
      "    var total = 0",
      "    for i in range(0, 5):",
      "        if i == 2:",
      "            continue",
      "        total += i",
      "    return total",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/for \(int32_t i = 0; i < 5; i \+= 1\) \{/, generated)
    assert_match(/if \(i == 2\) \{\n      continue;/, generated)
    refute_match(/goto __mt_loop_continue_\d+;/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
  end

  def test_generate_c_for_layout_queries_and_static_assert
    source = [
      "module demo.layout_surface",
      "",
      "struct Header:",
      "    magic: array[u8, 4]",
      "    version: u16",
      "",
      "static_assert(sizeof(Header) == 6, \"Header size should stay stable\")",
      "",
      "def main() -> usize:",
      "    return offsetof(Header, version) + alignof(Header)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/#include <stddef\.h>/, generated)
    assert_match(/_Static_assert\(sizeof\(demo_layout_surface_Header\) == 6, "Header size should stay stable"\);/, generated)
    assert_match(/return offsetof\(demo_layout_surface_Header, version\) \+ _Alignof\(demo_layout_surface_Header\);/, generated)
  end

  def test_generate_c_for_real_str_literals_and_panic
    source = [
      "module demo.str_surface",
      "",
      "const greeting: str = \"hello\"",
      "",
      "def main() -> i32:",
      "    panic(greeting)",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_str \{/, generated)
    assert_match(/char\* data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static const mt_str demo_str_surface_greeting = \(mt_str\)\{ \.data = "hello", \.len = 5 \};/, generated)
    assert_match(/static void mt_panic_str\(mt_str message\) \{/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/mt_panic_str\(demo_str_surface_greeting\);/, generated)
  end

  def test_generate_c_for_str_slice_and_arena_cstr_conversion
    source = [
      "module demo.str_methods_surface",
      "",
      "import std.str",
      "import std.mem.arena as arena",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    let text = \"hello world\"",
      "    let part = text.slice(6, 5)",
      "    let copied = part.to_cstr(ref_of(scratch))",
      "    panic(copied)",
      "    if part.len == usize<-5:",
      "        return i32<-part.len",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static mt_str str_slice\(mt_str this, uintptr_t start, uintptr_t len\)/, generated)
    assert_match(/str slice start must be a UTF-8 boundary/, generated)
    assert_match(/str slice end must be a UTF-8 boundary/, generated)
    assert_match(/return \(mt_str\)\{ \.data = this\.data \+ start, \.len = len \};/, generated)
    assert_match(/static const char\* std_mem_arena_Arena_to_cstr\(std_mem_arena_Arena \*this, mt_str text\)/, generated)
    assert_match(/uint8_t\* memory = std_mem_arena_Arena_alloc_bytes\(this, text\.len \+ 1\);/, generated)
    assert_match(/char \*buffer = \(\(char\*\) memory\);/, generated)
    assert_match(/\*\(buffer \+ text\.len\) = 0;/, generated)
    assert_match(/mt_str text = \(mt_str\)\{ \.data = "hello world", \.len = 11 \};/, generated)
    assert_match(/const char\* copied = str_to_cstr\(part, &scratch\);/, generated)
  end

  def test_rejects_codegen_for_direct_str_construction_outside_unsafe
    source = <<~MT
      module demo.bad_str_constructor

      def main(data: ptr[char], len: usize) -> str:
          return str(data = data, len = len)
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_source(source)
    end

    assert_match(/str construction requires unsafe/, error.message)
  end

  def test_generate_c_for_packed_and_aligned_structs
    source = [
      "module demo.layout_modifiers_surface",
      "",
      "packed struct Header:",
      "    tag: u8",
      "    value: u32",
      "",
      "align(16) struct Mat4:",
      "    data: array[f32, 16]",
      "",
      "static_assert(sizeof(Header) == 5, \"Header should stay packed\")",
      "static_assert(alignof(Mat4) == 16, \"Mat4 alignment drifted\")",
      "",
      "def main() -> i32:",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/struct demo_layout_modifiers_surface_Header \{/, generated)
    assert_match(/\} __attribute__\(\(packed\)\);/, generated)
    assert_match(/struct demo_layout_modifiers_surface_Mat4 \{/, generated)
    assert_match(/\} __attribute__\(\(aligned\(16\)\)\);/, generated)
    assert_match(/_Static_assert\(sizeof\(demo_layout_modifiers_surface_Header\) == 5, "Header should stay packed"\);/, generated)
    assert_match(/_Static_assert\(_Alignof\(demo_layout_modifiers_surface_Mat4\) == 16, "Mat4 alignment drifted"\);/, generated)
  end

  def test_generate_c_for_address_of_and_dereference_assignment
    source = [
      "module demo.pointer_surface",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(ref_of(counter))",
      "    unsafe:",
      "        read(counter_ptr).value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/\(\*counter_ptr\)\.value = 7;/, generated)
    assert_match(/return counter\.value;/, generated)
  end

  def test_generate_c_for_raw_pointer_member_access
    source = [
      "module demo.pointer_surface_auto_member",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(ref_of(counter))",
      "    unsafe:",
      "        counter_ptr.value = 7",
      "        return counter_ptr.value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_auto_member_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/counter_ptr->value = 7;/, generated)
    assert_match(/return counter_ptr->value;/, generated)
  end

  def test_generate_c_for_raw_pointer_method_calls
    source = [
      "module demo.pointer_method_surface",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "methods Counter:",
      "    edit def add(delta: i32):",
      "        this.value += delta",
      "",
      "    def read() -> i32:",
      "        return this.value",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(ref_of(counter))",
      "    unsafe:",
      "        counter_ptr.add(4)",
      "        return counter_ptr.read()",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static void demo_pointer_method_surface_Counter_add\(demo_pointer_method_surface_Counter \*this, int32_t delta\)/, generated)
    assert_match(/static int32_t demo_pointer_method_surface_Counter_read\(demo_pointer_method_surface_Counter this\)/, generated)
    assert_match(/demo_pointer_method_surface_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/demo_pointer_method_surface_Counter_add\(counter_ptr, 4\);/, generated)
    assert_match(/return demo_pointer_method_surface_Counter_read\(\*counter_ptr\);/, generated)
  end

  def test_generate_c_for_extended_compound_assignment_operators
    source = [
      "module demo.compound_assignments_surface",
      "",
      "flags Bits: u32",
      "    a = 1 << 0",
      "    b = 1 << 1",
      "",
      "def main() -> i32:",
      "    var value = 12",
      "    value %= 5",
      "    value <<= 1",
      "    value >>= 1",
      "    var bits = Bits.a",
      "    bits |= Bits.b",
      "    bits &= Bits.b",
      "    bits ^= Bits.a",
      "    return value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/value %= 5;/, generated)
    assert_match(/value <<= 1;/, generated)
    assert_match(/value >>= 1;/, generated)
    assert_match(/bits \|= demo_compound_assignments_surface_Bits_b;/, generated)
    assert_match(/bits &= demo_compound_assignments_surface_Bits_b;/, generated)
    assert_match(/bits \^= demo_compound_assignments_surface_Bits_a;/, generated)
  end

  def test_generate_c_for_safe_ref_locals_params_and_methods
    source = [
      "module demo.ref_surface",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "methods Counter:",
      "    edit def add(delta: i32):",
      "        this.value += delta",
      "",
      "    def read() -> i32:",
      "        return this.value",
      "",
      "def increment(counter: ref[Counter], amount: i32) -> void:",
      "    counter.add(amount)",
      "    counter.value += 1",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let handle = ref_of(counter)",
      "    increment(handle, 4)",
      "    let value_ref = ref_of(handle.value)",
      "    read(value_ref) += 2",
      "    unsafe:",
      "        let raw_counter = ptr_of(handle)",
      "        read(raw_counter).value += 1",
      "    return handle.read()",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static void demo_ref_surface_Counter_add\(demo_ref_surface_Counter \*this, int32_t delta\)/, generated)
    assert_match(/static int32_t demo_ref_surface_Counter_read\(demo_ref_surface_Counter this\)/, generated)
    assert_match(/static void demo_ref_surface_increment\(demo_ref_surface_Counter \*counter, int32_t amount\)/, generated)
    assert_match(/demo_ref_surface_Counter \*handle = &counter;/, generated)
    assert_match(/demo_ref_surface_increment\(handle, 4\);/, generated)
    assert_match(/demo_ref_surface_Counter_add\(counter, amount\);/, generated)
    assert_match(/counter->value \+= 1;/, generated)
    assert_match(/int32_t \*value_ref = &handle->value;/, generated)
    assert_match(/\*value_ref \+= 2;/, generated)
    assert_match(/demo_ref_surface_Counter \*raw_counter = handle;/, generated)
    assert_match(/\(\*raw_counter\)\.value \+= 1;/, generated)
    assert_match(/return demo_ref_surface_Counter_read\(\*handle\);/, generated)
  end

  def test_generate_c_for_imported_associated_functions_on_type_aliases
    Dir.mktmpdir("milk-tea-codegen-associated") do |dir|
      FileUtils.mkdir_p(File.join(dir, "demo"))

      File.write(File.join(dir, "demo", "math.mt"), [
        "module demo.math",
        "",
        "pub struct RawVec:",
        "    x: i32",
        "",
        "pub type Vec = RawVec",
        "",
        "methods RawVec:",
        "    pub static def zero() -> Vec:",
        "        return Vec(x = 0)",
        "",
      ].join("\n"))

      source_path = File.join(dir, "main.mt")
      File.write(source_path, [
        "module demo.main",
        "",
        "import demo.math as math",
        "",
        "def main() -> i32:",
        "    let value = math.Vec.zero()",
        "    return value.x",
        "",
      ].join("\n"))

      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(source_path)
      generated = MilkTea::Codegen.generate_c(program)

      assert_match(/static demo_math_RawVec demo_math_RawVec_zero\(void\)/, generated)
      assert_match(/demo_math_RawVec value = demo_math_RawVec_zero\(\);/, generated)
      assert_match(/return value\.x;/, generated)
    end
  end

  def test_generate_c_for_fixed_array_construction_and_layout
    source = [
      "module demo.array_surface",
      "",
      "struct Palette:",
      "    colors: array[u32, 4]",
      "",
      "const DEFAULT: array[u32, 4] = array[u32, 4](11, 22, 33, 44)",
      "",
      "def main() -> i32:",
      "    var palette = array[u32, 4](1, 2, 3, 4)",
      "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
      "    unsafe:",
      "        if read(ptr_of(ref_of(palette[0]))) != 1:",
      "            return 1",
      "        if read(ptr_of(ref_of(holder.colors[0]))) != 5:",
      "            return 2",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_array_surface_Palette/, generated)
    assert_match(/uint32_t colors\[4\];/, generated)
    assert_match(/static const uint32_t demo_array_surface_DEFAULT\[4\] = \{ 11, 22, 33, 44 \};/, generated)
    assert_match(/uint32_t palette\[4\] = \{ 1, 2, 3, 4 \};/, generated)
    assert_match(/\.colors = \{ 5, 6, 7, 8 \}/, generated)
  end

  def test_generate_c_for_addr_of_fixed_array_element_through_pointer_deref
    source = [
      "module demo.ptr_array_addr",
      "",
      "struct Palette:",
      "    colors: array[u32, 4]",
      "",
      "def main() -> u32:",
      "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
      "    unsafe:",
      "        let base = ptr_of(ref_of(holder))",
      "        let first = ptr_of(ref_of(read(base).colors[0]))",
      "        read(first) = 9",
      "    return holder.colors[0]",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_ptr_array_addr_Palette \*base = &holder;/, generated)
    assert_match(/uint32_t \*first = mt_checked_index_array_u32_4\(&\(\(\*base\)\.colors\), 0\);/, generated)
    assert_match(/\*first = 9;/, generated)
    assert_match(/return \(\*mt_checked_index_array_u32_4\(&\(holder\.colors\), 0\)\);/, generated)
  end

  def test_generate_c_hoists_repeated_checked_index_helper_within_expression_statement
    source = [
      "module demo.checked_index_alias_surface",
      "",
      "struct Point:",
      "    x: i32",
      "    y: i32",
      "",
      "def use(a: i32, b: i32, c: i32, d: i32) -> void:",
      "    return",
      "",
      "def next(cursor: ptr[i32]) -> i32:",
      "    unsafe:",
      "        let value = read(cursor)",
      "        read(cursor) += 1",
      "        return value",
      "",
      "def main() -> i32:",
      "    var points = array[Point, 2](Point(x = 1, y = 2), Point(x = 3, y = 4))",
      "    var index = 1",
      "    use(points[index].x, points[index].y, points[index].x + points[index].y, points[index].x)",
      "    var cursor = 0",
      "    use(points[next(ptr_of(ref_of(cursor)))].x, points[next(ptr_of(ref_of(cursor)))].y, 0, 0)",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_checked_index_alias_surface_Point \*__mt_checked_index_ptr_\d+ = mt_checked_index_array_demo_checked_index_alias_surface_Point_2\(&\(points\), index\);/, generated)
    assert_match(/demo_checked_index_alias_surface_use\(__mt_checked_index_ptr_\d+->x, __mt_checked_index_ptr_\d+->y, __mt_checked_index_ptr_\d+->x \+ __mt_checked_index_ptr_\d+->y, __mt_checked_index_ptr_\d+->x\);/, generated)
    refute_match(/demo_checked_index_alias_surface_Point \*__mt_checked_index_ptr_\d+ = mt_checked_index_array_demo_checked_index_alias_surface_Point_2\(&\(points\), demo_checked_index_alias_surface_next\(&cursor\)\);/, generated)
  end

  def test_generate_c_for_safe_array_indexing_and_assignment
    source = [
      "module demo.array_index_surface",
      "",
      "struct Palette:",
      "    colors: array[u32, 4]",
      "",
      "def main() -> i32:",
      "    var palette = array[u32, 4](1, 2, 3, 4)",
      "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
      "    palette[1] = 9",
      "    holder.colors[2] = 10",
      "    if palette[0] != 1:",
      "        return 1",
      "    if holder.colors[2] != 10:",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static inline uint32_t \*mt_checked_index_array_u32_4\(uint32_t \(\*array\)\[4\], uintptr_t index\)/, generated)
    assert_match(/if \(index >= 4\) mt_panic\("array index out of bounds"\);/, generated)
    assert_match(/\(\*mt_checked_index_array_u32_4\(\&\(palette\), 1\)\) = 9;/, generated)
    assert_match(/\(\*mt_checked_index_array_u32_4\(\&\(holder\.colors\), 2\)\) = 10;/, generated)
    assert_match(/if \(\(\(\*mt_checked_index_array_u32_4\(\&\(palette\), 0\)\)\) != 1\)/, generated)
  end

  def test_generate_c_for_zero_initialization
    source = [
      "module demo.zero_surface",
      "",
      "struct Palette:",
      "    colors: array[u32, 4]",
      "",
      "def main() -> i32:",
      "    var palette = zero[array[u32, 4]]()",
      "    var holder = zero[Palette]()",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/uint32_t palette\[4\] = \{ 0 \};/, generated)
    assert_match(/demo_zero_surface_Palette holder = \{ 0 \};/, generated)
  end

  def test_generate_c_for_partial_aggregate_and_array_initialization
    source = [
      "module demo.partial_surface",
      "",
      "struct Point:",
      "    x: i32",
      "    y: i32",
      "",
      "def main() -> i32:",
      "    var origin = Point()",
      "    var point = Point(x = 5)",
      "    var palette = array[u32, 4](1, 2)",
      "    return origin.x + point.x + i32<-palette[1]",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_partial_surface_Point origin = \(demo_partial_surface_Point\) \{ 0 \};/, generated)
    assert_match(/demo_partial_surface_Point point = \(demo_partial_surface_Point\)\{ \.x = 5 \};/, generated)
    assert_match(/uint32_t palette\[4\] = \{ 1, 2 \};/, generated)
  end

  def test_generate_c_for_array_assignment_and_parameter_copy
    source = [
      "module demo.array_copy_surface",
      "",
      "def mutate(values: array[i32, 4]) -> i32:",
      "    var local = values",
      "    unsafe:",
      "        local[1] = 9",
      "        return local[1]",
      "",
      "def main() -> i32:",
      "    var lhs = array[i32, 4](1, 2, 3, 4)",
      "    let rhs = array[i32, 4](5, 6, 7, 8)",
      "    lhs = rhs",
      "    let changed = mutate(lhs)",
      "    unsafe:",
      "        if lhs[1] != 6:",
      "            return 1",
      "    return changed",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/int32_t values_input\[4\]/, generated)
    assert_match(/static inline int32_t \*mt_checked_index_array_i32_4\(int32_t \(\*array\)\[4\], uintptr_t index\)/, generated)
    assert_match(/int32_t values\[4\];\n  memcpy\(values, values_input, sizeof\(values\)\);/, generated)
    assert_match(/int32_t local\[4\];\n  memcpy\(local, values, sizeof\(local\)\);/, generated)
    assert_match(/memcpy\(lhs, rhs, sizeof\(lhs\)\);/, generated)
    assert_match(/return \(\*mt_checked_index_array_i32_4\(\&\(local\), 1\)\);/, generated)
    assert_match(/if \(\(\(\*mt_checked_index_array_i32_4\(\&\(lhs\), 1\)\)\) != 6\)/, generated)
  end

  def test_generate_c_for_local_array_returns
    source = [
      "module demo.array_return_surface",
      "",
      "def make() -> array[i32, 4]:",
      "    return array[i32, 4](1, 2, 3, 4)",
      "",
      "def clone(values: array[i32, 4]) -> array[i32, 4]:",
      "    return values",
      "",
      "def read(values: array[i32, 4]) -> i32:",
      "    unsafe:",
      "        return values[1]",
      "",
      "def main() -> i32:",
      "    return read(clone(make()))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_array_return_array_i32_4/, generated)
    assert_match(/static mt_array_return_array_i32_4 demo_array_return_surface_make\(void\)/, generated)
    assert_match(/return \(mt_array_return_array_i32_4\)\{ \.value = \{ 1, 2, 3, 4 \} \};/, generated)
    assert_match(/mt_array_return_array_i32_4 __mt_return_value;/, generated)
    assert_match(/memcpy\(__mt_return_value\.value, values, sizeof\(__mt_return_value\.value\)\);/, generated)
    assert_match(/return demo_array_return_surface_read\(demo_array_return_surface_clone\(demo_array_return_surface_make\(\)\.value\)\.value\);/, generated)
  end

  def test_generate_c_for_unsafe_reinterpret_calls
    source = [
      "module demo.reinterpret_surface",
      "",
      "def main() -> u32:",
      "    let value: f32 = 1.0",
      "    unsafe:",
      "        let bits = reinterpret[u32](value)",
      "        return bits",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static inline uint32_t mt_reinterpret_u32_from_f32\(float value\)/, generated)
    assert_match(/_Static_assert\(sizeof\(uint32_t\) == sizeof\(float\), "reinterpret requires equal sizes"\);/, generated)
    assert_match(/memcpy\(&result, &value, sizeof\(result\)\);/, generated)
    assert_match(/uint32_t bits = mt_reinterpret_u32_from_f32\(value\);/, generated)
  end

  def test_generate_c_for_unsafe_pointer_to_cstr_abi_casts
    source = [
      "module demo.cstr_casts_surface",
      "",
      "extern def set_text(value: cstr) -> void",
      "extern def get_text() -> cstr",
      "",
      "def main() -> void:",
      "    var buffer = zero[array[char, 32]]()",
      "    unsafe:",
      "        let raw_buffer = ptr_of(ref_of(buffer[0]))",
      "        set_text(cstr<-raw_buffer)",
      "        let clipboard = get_text()",
      "        let writable = ptr[char]<-clipboard",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/set_text\(\(\(const char\*\) raw_buffer\)\);/, generated)
    assert_match(/char \*writable = \(\(char\*\) clipboard\);/, generated)
  end

  def test_generate_c_for_const_pointer_ro_addr_calls
    source = [
      "module demo.const_pointer_call_surface",
      "",
      "def inspect(values: const_ptr[i32]) -> void:",
      "    return",
      "",
      "def main() -> void:",
      "    let value = 7",
      "    inspect(const_ptr_of(value))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static void demo_const_pointer_call_surface_inspect\(const int32_t\* values\)/, generated)
    assert_match(/demo_const_pointer_call_surface_inspect\(\&value\);/, generated)
  end

  def test_generate_c_for_array_char_values_and_span_char_calls
    source = [
      "module demo.char_array_surface",
      "",
      "def view(items: span[char]) -> usize:",
      "    return items.len",
      "",
      "def main() -> i32:",
      "    var buffer = zero[array[char, 32]]()",
      "    buffer[0] = 65",
      "    return i32<-view(buffer)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/char buffer\[32\] = \{ 0 \};/, generated)
    assert_match(/\(\*mt_checked_index_array_char_32\(&\(buffer\), 0\)\) = \(\(char\) 65\);/, generated)
    assert_match(/\(mt_span_char\)\{ \.data = &buffer\[0\], \.len = 32 \}/, generated)
  end

  def test_generate_c_for_typed_array_char_local_without_initializer
    source = [
      "module demo.char_array_zero_local",
      "",
      "def main() -> i32:",
      "    var buffer: array[char, 16]",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/char buffer\[16\] = \{ 0 \};/, generated)
  end

  def test_rejects_generate_c_for_array_char_text_methods
    source = [
      "module demo.char_array_methods",
      "",
      "def main() -> i32:",
      "    var buffer = zero[array[char, 16]]()",
      "    let view = buffer.as_str()",
      "    let label = buffer.as_cstr()",
      "    return i32<-view.len",
      "",
    ].join("\n")

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_source(source)
    end

    assert_match(/array\[char, 16\]\.as_str is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_generate_c_for_str_builder_methods_and_span_char_calls
    source = [
      "module demo.str_builder_surface",
      "",
      "def view(items: span[char]) -> usize:",
      "    return items.len",
      "",
      "def main() -> i32:",
      "    var buffer: str_builder[32]",
      "    buffer.assign(\"hi\")",
      "    buffer.append(\"!\")",
      "    let text = buffer.as_str()",
      "    let label = buffer.as_cstr()",
      "    let raw = view(buffer)",
      "    buffer.clear()",
      "    return i32<-(buffer.capacity() + text.len + raw)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_str_builder_32 mt_str_builder_32;/, generated)
    assert_match(/struct mt_str_builder_32 \{/, generated)
    assert_match(/char data\[33\];/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/bool dirty;/, generated)
    assert_match(/static char\* mt_str_builder_prepare_write\(char\* data, uintptr_t cap, bool\* dirty\)/, generated)
    assert_match(/static uintptr_t mt_str_builder_len\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static const char\* mt_str_builder_as_cstr\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_builder_assign\(mt_str value, char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_builder_append\(mt_str value, char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/static void mt_str_builder_clear\(char\* data, uintptr_t cap, uintptr_t\* len, bool\* dirty\)/, generated)
    assert_match(/mt_str_builder_32 buffer = \{ 0 \};/, generated)
    assert_match(/mt_str_builder_assign\(\(mt_str\)\{ \.data = "hi", \.len = 2 \}, &buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/mt_str_builder_append\(\(mt_str\)\{ \.data = "!", \.len = 1 \}, &buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/mt_str text = \(mt_str\)\{ \.data = &buffer\.data\[0\], \.len = mt_str_builder_len\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\) \};/, generated)
    assert_match(/const char\* label = mt_str_builder_as_cstr\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
    assert_match(/\(mt_span_char\)\{ \.data = mt_str_builder_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \.len = 33 \}/, generated)
    assert_match(/mt_str_builder_clear\(&buffer\.data\[0\], 32, &buffer\.len, &buffer\.dirty\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_str_builder_and_span_char_ptr_char_boundary
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

        pub foreign def text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, i32<-text_public.len)
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/mt_span_char __mt_foreign_arg_public_1 = \(mt_span_char\)\{ \.data = mt_str_builder_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \.len = 33 \};/, generated)
    assert_match(/TextBox\(__mt_foreign_arg_public_1\.data, \(\(int32_t\) __mt_foreign_arg_public_1\.len\)\);/, generated)
  end

  def test_generate_c_for_generic_foreign_defs_with_str_builder_public_capacity_mapping
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

        pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, i32<-(text_public.capacity() + 1))
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_builder_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(\(int32_t\) (?:33|\(32 \+ 1\))\)\);/, generated)
  end

  def test_generate_c_for_explicit_literal_specialization_on_imported_generic_foreign_defs
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

        pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, i32<-(text_public.capacity() + 1))
      MT
    }

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_builder_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(\(int32_t\) (?:33|\(32 \+ 1\))\)\);/, generated)
  end

  def test_generate_c_for_explicit_literal_specialization_on_local_generic_foreign_defs
    root_source = <<~MT
      module demo.main

      import std.c.ui as c

      pub foreign def text_box[N](text: str_builder[N] as ptr[char]) -> void = c.TextBox(text, i32<-(text_public.capacity() + 1))

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

    generated = generate_c_from_program_source(root_source, imported_sources)

    assert_match(/TextBox\(mt_str_builder_prepare_write\(&buffer\.data\[0\], 32, &buffer\.dirty\), \(\(int32_t\) (?:33|\(32 \+ 1\))\)\);/, generated)
  end

  def test_rejects_codegen_for_removed_cstr_list_buffer_type
    source = <<~MT
      module demo.main

      def main() -> void:
          var labels: cstr_list_buffer[3, 64]
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_program_source(source)
    end

    assert_match(/unknown generic type cstr_list_buffer/, error.message)
  end

  def test_rejects_generate_c_for_foreign_str_as_cstr_call_with_array_char_as_cstr
    source = <<~MT
      module demo.main

      import std.ui as ui

      def main() -> void:
          var buffer: array[char, 32]
          ui.label(buffer.as_cstr())
    MT

    imported_sources = {
      "std/c/ui.mt" => <<~MT,
        extern module std.c.ui:
            include "ui.h"

            extern def Label(text: cstr) -> void
      MT
      "std/ui.mt" => <<~MT,
        module std.ui

        import std.c.ui as c

        pub foreign def label(text: str as cstr) -> void = c.Label
      MT
    }

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_program_source(source, imported_sources)
    end

    assert_match(/array\[char, 32\]\.as_cstr is not available; array\[char, N\] is raw storage/, error.message)
  end

  def test_generate_c_for_foreign_defs_with_array_char_and_span_char_ptr_char_boundary
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/WriteFixed\(&fixed\[0\]\);/, generated)
    assert_match(/WriteDynamic\(\(\(mt_span_char\)\{ \.data = &dynamic\[0\], \.len = 64 \}\)\.data\);/, generated)
  end

  def test_generate_c_for_foreign_mapping_public_alias_boundary_and_length
    source = <<~MT
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

        pub foreign def text_box(text: span[char] as ptr[char]) -> void = c.TextBox(text, i32<-text_public.len)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_span_char __mt_foreign_arg_public_\d+ = \(mt_span_char\)\{ \.data = &buffer\[0\], \.len = 32 \};/, generated)
    assert_match(/TextBox\(__mt_foreign_arg_public_\d+\.data, \(\(int32_t\) __mt_foreign_arg_public_\d+\.len\)\);/, generated)
  end

  def test_generate_c_for_unsafe_typed_null_pointer_to_cstr_casts
    source = [
      "module demo.typed_null_cstr_surface",
      "",
      "extern def set_text(value: cstr) -> void",
      "",
      "def main() -> void:",
      "    unsafe:",
      "        set_text(cstr<-null[ptr[char]])",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/set_text\(\(\(const char\*\) NULL\)\);/, generated)
  end

  def test_generate_c_for_unsafe_integer_to_char_buffer_writes
    source = [
      "module demo.char_buffer_surface",
      "",
      "def main() -> i32:",
      "    var ptr: ptr[char] = zero[ptr[char]]()",
      "    unsafe:",
      "        ptr[0] = 65",
      "        ptr[1] = char<-66",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/ptr\[0\] = \(\(char\) 65\);/, generated)
    assert_match(/ptr\[1\] = \(\(char\) 66\);/, generated)
  end

  def test_generate_c_for_unsafe_pointer_offsets_without_usize_casts
    source = [
      "module demo.pointer_offset_surface",
      "",
      "def main() -> i32:",
      "    var ptr: ptr[char] = zero[ptr[char]]()",
      "    let offset = 1",
      "    unsafe:",
      "        var next = ptr + offset",
      "        next[offset - 1] = 65",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/char \*next = ptr \+ offset;/, generated)
    assert_match(/next\[offset - 1\] = \(\(char\) 65\);/, generated)
  end

  def test_generate_c_for_ref_arguments_passed_to_by_value_parameters
    source = [
      "module demo.ref_value_args",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "extern def consume(counter: Counter) -> void",
      "",
      "def project(counter: Counter) -> i32:",
      "    return counter.value",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 7)",
      "    let handle = ref_of(counter)",
      "    consume(read(handle))",
      "    return project(read(handle))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/consume\(\*handle\);/, generated)
    assert_match(/return demo_ref_value_args_project\(\*handle\);/, generated)
  end

  def test_generate_c_for_left_biased_float_literal_inference
    source = [
      "module demo.float_literal_inference",
      "",
      "def main() -> i32:",
      "    let value: f32 = 4.0",
      "    let inverse = 1.0 / value",
      "    let scaled = -2.0 / value",
      "    if inverse > scaled:",
      "        return 0",
      "    return 1",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/float inverse = 1\.0f \/ value;/, generated)
    assert_match(/float scaled = \(-2\.0f\) \/ value;/, generated)
  end

  def test_generate_c_for_callable_value_storage_and_indirect_calls
    source = [
      "module demo.callable_values",
      "",
      "struct Entry:",
      "    callback: fn(value: f32) -> f32",
      "",
      "def identity(value: i32) -> i32:",
      "    return value",
      "",
      "def ease(value: f32) -> f32:",
      "    return value + 2.0",
      "",
      "def main() -> i32:",
      "    let callbacks = array[fn(value: i32) -> i32, 1](identity)",
      "    let entry = Entry(callback = ease)",
      "    let callback: fn(value: f32) -> f32 = entry.callback",
      "    let left = callbacks[0](1)",
      "    let right = callback(1.0)",
      "    return left + i32<-right",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/float \(\*callback\)\(float value\);/, generated)
    assert_match(/int32_t \(\*callbacks\[1\]\)\(int32_t value\)/, generated)
    assert_match(/int32_t left = \(\(\*mt_checked_index_array_fn_1\(&\(callbacks\), 0\)\)\)\(1\);/, generated)
    assert_match(/float right = callback\(1\.0f\);/, generated)
  end

  def test_generate_c_for_imported_function_callable_values
    source = [
      "module demo.main",
      "",
      "import std.ease as ease",
      "",
      "struct Entry:",
      "    callback: fn(value: i32) -> i32",
      "",
      "def main() -> i32:",
      "    let callbacks = array[fn(value: i32) -> i32, 1](ease.double)",
      "    let entry = Entry(callback = ease.double)",
      "    return callbacks[0](3) + entry.callback(4)",
      "",
    ].join("\n")

    imported_sources = {
      "std/ease.mt" => [
        "module std.ease",
        "",
        "pub def double(value: i32) -> i32:",
        "    return value * 2",
        "",
      ].join("\n"),
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/int32_t \(\*callbacks\[1\]\)\(int32_t value\) = \{ std_ease_double \};/, generated)
    assert_match(/\.callback = std_ease_double/, generated)
    assert_match(/return \(\(\*mt_checked_index_array_fn_1\(&\(callbacks\), 0\)\)\)\(3\) \+ entry\.callback\(4\);/, generated)
  end

  def test_generate_c_for_proc_closure_capture_and_param_calls
    source = [
      "module demo.proc_codegen",
      "",
      "def apply(callback: proc(value: i32) -> i32, value: i32) -> i32:",
      "    return callback(value)",
      "",
      "def main() -> i32:",
      "    let offset = 4",
      "    let callback = proc(value: i32) -> i32:",
      "        return value * 2 + offset",
      "    return apply(callback, 3)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_proc_proc_i32_i32/, generated)
    assert_match(/typedef struct demo_proc_codegen__proc_1__env/, generated)
    assert_match(/malloc\(sizeof\(demo_proc_codegen__proc_1__env\)\)/, generated)
    assert_match(/\.invoke = demo_proc_codegen__proc_1__invoke/, generated)
    assert_match(/\.release = demo_proc_codegen__proc_1__release/, generated)
    assert_match(/\.retain = demo_proc_codegen__proc_1__retain/, generated)
    assert_match(/callback\.invoke\(callback\.env, value\)/, generated)
  end

  def test_generate_c_for_proc_return_and_struct_field
    source = [
      "module demo.proc_surface",
      "",
      "struct Holder:",
      "    callback: proc(value: i32) -> i32",
      "",
      "def factory(offset: i32) -> proc(value: i32) -> i32:",
      "    return proc(value: i32) -> i32:",
      "        return value + offset",
      "",
      "def call(holder: Holder, value: i32) -> i32:",
      "    return holder.callback(value)",
      "",
      "def main() -> i32:",
      "    let cb = factory(2)",
      "    let holder = Holder(callback = cb)",
      "    return call(holder, 40)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct demo_proc_surface_Holder/, generated)
    assert_match(/cb\.retain\(cb\.env\);/, generated)
    assert_match(/holder\.callback\.invoke\(holder\.callback\.env, value\)/, generated)
    assert_match(/holder\.callback\.release\(holder\.callback\.env\);/, generated)
  end

  def test_generate_c_for_async_proc_param_lifecycle
    source = [
      "module demo.async_proc_lifecycle",
      "",
      "async def run(callback: proc(value: i32) -> i32) -> i32:",
      "    return callback(1)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    # Constructor must retain the proc param so the frame outlives the caller's copy.
    assert_match(/param_callback\.retain\(__mt_frame->param_callback\.env\)/, generated)
    # Release function must null-guard release the proc param field before freeing the frame.
    assert_match(/if \(__mt_frame->param_callback\.invoke\)/, generated)
    assert_match(/__mt_frame->param_callback\.release\(__mt_frame->param_callback\.env\)/, generated)
  end

  def test_generate_c_for_async_proc_local_lifecycle
    source = [
      "module demo.async_proc_local",
      "",
      "async def run(offset: i32) -> i32:",
      "    let callback = proc(value: i32) -> i32:",
      "        return value + offset",
      "    return callback(1)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    # Local proc stored in frame; no extra retain (frame owns freshly-allocated env).
    # Release function must null-guard release the local proc field before freeing the frame.
    assert_match(/if \(__mt_frame->local_callback\.invoke\)/, generated)
    assert_match(/__mt_frame->local_callback\.release\(__mt_frame->local_callback\.env\)/, generated)
  end

  def test_generate_c_for_proc_assignment_lifecycle
    source = [
      "module demo.proc_assign_lifecycle",
      "",
      "struct Holder:",
      "    callback: proc(value: i32) -> i32",
      "",
      "def main() -> i32:",
      "    let ca = proc(value: i32) -> i32:",
      "        return value + 1",
      "    let cb = proc(value: i32) -> i32:",
      "        return value + 2",
      "    let a = Holder(callback = ca)",
      "    var b = Holder(callback = cb)",
      "    b = a",
      "    return b.callback(1)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    # Struct assignment retain: ca is an existing proc read(not a direct proc expr in the assignment RHS),
    # so it gets retained for b's ownership.
    assert_match(/__mt_proc_assign_\d+\.callback\.retain\(__mt_proc_assign_\d+\.callback\.env\)/, generated)
    # Old b.callback released (guarded) before overwrite.
    assert_match(/if \(b\.callback\.invoke\)/, generated)
    assert_match(/b\.callback\.release\(b\.callback\.env\)/, generated)
    # Deferred cleanup uses null-guarded release on all proc-containing locals.
    assert_match(/if \(a\.callback\.invoke\)/, generated)
    assert_match(/a\.callback\.release\(a\.callback\.env\)/, generated)
  end

  def test_generate_c_for_proc_field_assignment_lifecycle
    source = [
      "module demo.proc_field_assign",
      "",
      "struct Holder:",
      "    callback: proc(value: i32) -> i32",
      "",
      "def main() -> i32:",
      "    let ca = proc(value: i32) -> i32:",
      "        return value + 1",
      "    var h = Holder(callback = ca)",
      "    let cb = proc(value: i32) -> i32:",
      "        return value + 2",
      "    h.callback = cb",
      "    return h.callback(1)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    # h.callback = cb: cb is an existing proc (let cb = ..., not a direct proc expr in the field assignment).
    # Retain is emitted, old field is released.
    assert_match(/__mt_proc_assign_\d+\.retain\(__mt_proc_assign_\d+\.env\)/, generated)
    assert_match(/if \(h\.callback\.invoke\)/, generated)
    assert_match(/h\.callback\.release\(h\.callback\.env\)/, generated)
  end

  def test_generate_c_for_proc_var_reassign_lifecycle
    source = [
      "module demo.proc_var_reassign",
      "",
      "def main() -> i32:",
      "    var callback = proc(value: i32) -> i32:",
      "        return value + 1",
      "    callback = proc(value: i32) -> i32:",
      "        return value + 2",
      "    return callback(0)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    # Reassignment with a fresh proc expr: no retain (transfer ownership), but old callback is released.
    assert_match(/if \(callback\.invoke\)/, generated)
    assert_match(/callback\.release\(callback\.env\)/, generated)
  end

  def test_generate_c_for_module_scope_mutable_vars
    source = [
      "module demo.global_state",
      "",
      "const BASE: i32 = 1",
      "",
      "def identity(value: i32) -> i32:",
      "    return value",
      "",
      "var counter: i32 = BASE",
      "var scratch: array[u8, 4]",
      "var callbacks: array[fn(value: i32) -> i32, 1] = array[fn(value: i32) -> i32, 1](identity)",
      "",
      "def main() -> i32:",
      "    counter = callbacks[0](counter)",
      "    return counter + i32<-scratch[0]",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_global_state_counter = 1;/, generated)
    assert_match(/static uint8_t demo_global_state_scratch\[4\] = \{ 0 \};/, generated)
    assert_match(/static int32_t \(\*demo_global_state_callbacks\[1\]\)\(int32_t value\) = \{ demo_global_state_identity \};/, generated)
    refute_match(/static int32_t demo_global_state_counter = demo_global_state_BASE;/, generated)
  end

  def test_generate_c_for_integer_match_with_default_case
    source = [
      "module demo.int_match",
      "",
      "def dispatch(key: i32) -> i32:",
      "    match key:",
      "        65:",
      "            return 1",
      "        27:",
      "            return 2",
      "        _:",
      "            return 0",
      "",
      "def main() -> i32:",
      "    return dispatch(65)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/switch \(key\) \{/, generated)
    assert_match(/case 65: \{/, generated)
    assert_match(/case 27: \{/, generated)
    assert_match(/default: \{/, generated)
    assert_match(/return 1;/, generated)
    assert_match(/return 2;/, generated)
    assert_match(/return 0;/, generated)
    refute_match(/case 0:/, generated)
  end

  def test_generate_c_for_enum_match_with_wildcard
    source = [
      "module demo.enum_wild",
      "",
      "enum EventKind: u8",
      "    quit = 1",
      "    resize = 2",
      "    key = 3",
      "",
      "def dispatch(kind: EventKind) -> i32:",
      "    match kind:",
      "        EventKind.quit:",
      "            return 0",
      "        _:",
      "            return 1",
      "",
      "def main() -> i32:",
      "    return dispatch(EventKind.quit)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/switch \(kind\) \{/, generated)
    assert_match(/case demo_enum_wild_EventKind_quit: \{/, generated)
    assert_match(/default: \{/, generated)
    assert_match(/return 0;/, generated)
    assert_match(/return 1;/, generated)
  end

  def test_generate_c_for_variant_tagged_union_structs
    source = <<~MT
      module demo.variant_codegen

      variant Token:
          ident(text: str)
          number(value: i32)
          eof

      def kind_of(tok: Token) -> i32:
          match tok:
              Token.ident:
                  return 0
              Token.number:
                  return 1
              Token.eof:
                  return 2
    MT

    generated = generate_c_from_source(source)

    # Kind typedef and constants
    assert_match(/typedef int32_t demo_variant_codegen_Token_kind;/, generated)
    assert_match(/demo_variant_codegen_Token_kind_ident = 0/, generated)
    assert_match(/demo_variant_codegen_Token_kind_number = 1/, generated)
    assert_match(/demo_variant_codegen_Token_kind_eof = 2/, generated)
    # Per-arm payload structs emitted
    assert_match(/struct demo_variant_codegen_Token_ident \{/, generated)
    assert_match(/struct demo_variant_codegen_Token_number \{/, generated)
    # Data union (ident and number have payloads)
    assert_match(/union demo_variant_codegen_Token__data \{/, generated)
    # Outer struct with kind and data fields
    assert_match(/struct demo_variant_codegen_Token \{/, generated)
    assert_match(/demo_variant_codegen_Token_kind kind;/, generated)
    # Typedef
    assert_match(/typedef struct demo_variant_codegen_Token demo_variant_codegen_Token;/, generated)
    # Match on .kind
    assert_match(/switch \(.*\.kind\)/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_ident:/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_number:/, generated)
    assert_match(/case demo_variant_codegen_Token_kind_eof:/, generated)
  end

  def test_generate_c_for_variant_construction
    source = <<~MT
      module demo.variant_ctor_codegen

      variant Event:
          click(x: i32, y: i32)
          quit

      def make_quit() -> Event:
          return Event.quit

      def make_click(x: i32, y: i32) -> Event:
          return Event.click(x= x, y= y)
    MT

    generated = generate_c_from_source(source)

    # No-payload arm literal
    assert_match(/demo_variant_ctor_codegen_Event_kind_quit/, generated)
    # Payload arm literal references kind constant and struct
    assert_match(/demo_variant_ctor_codegen_Event_kind_click/, generated)
    assert_match(/\.kind = demo_variant_ctor_codegen_Event_kind_click/, generated)
  end

  def test_generate_c_for_variant_as_binding_field_access
    source = <<~MT
      module demo.variant_as_binding

      variant Shape:
          circle(radius: f64)
          point

      def area(s: Shape) -> f64:
          match s:
              Shape.circle as c:
                  return c.radius * c.radius
              Shape.point:
                  return 0.0
    MT

    generated = generate_c_from_source(source)

    # as-binding declared with struct type and initialized from .data
    assert_match(/demo_variant_as_binding_Shape_circle/, generated)
    assert_match(/\.radius/, generated)
    assert_match(/return 0\.0/, generated)
  end

  def test_generate_c_for_generic_variant_instances
    source = <<~MT
      module demo.generic_variant_codegen

      variant Option[T]:
          some(value: T)
          none

      def unwrap_or_zero(value: Option[i32]) -> i32:
          match value:
              Option.some as payload:
                  return payload.value
              Option.none:
                  return 0

      def main() -> i32:
          let value: Option[i32] = Option[i32].some(value= 7)
          return unwrap_or_zero(value)
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef int32_t demo_generic_variant_codegen_Option_i32_kind;/, generated)
    assert_match(/struct demo_generic_variant_codegen_Option_i32_some \{/, generated)
    assert_match(/struct demo_generic_variant_codegen_Option_i32 \{/, generated)
    assert_match(/demo_generic_variant_codegen_Option_i32_kind kind;/, generated)
    assert_match(/case demo_generic_variant_codegen_Option_i32_kind_some:/, generated)
    assert_match(/case demo_generic_variant_codegen_Option_i32_kind_none:/, generated)
    assert_match(/demo_generic_variant_codegen_Option_i32_some payload = .*\.data\.some;/, generated)
  end

  def test_generate_c_for_union_with_proc_field
    source = <<~MT
      module demo.union_proc_codegen

      union CallbackOrValue:
          callback: proc() -> i32
          value: i32

      def main() -> i32:
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_proc_/, generated)
    assert_match(/typedef union demo_union_proc_codegen_CallbackOrValue/, generated)
    assert_match(/mt_proc_.* callback;/, generated)
  end

  def test_generate_c_format_precision_spec_calls_append_f64_precision
    source = <<~MT
      module demo.fmt_spec

      import std.io as io

      def main(pi: f64, small: f32) -> i32:
          io.println(f"pi=\#{pi:.2}")
          io.println(f"small=\#{small:.5}")
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/std_fmt_append_f64_precision\(/, generated)
    assert_match(/,\s*2\s*\)/, generated)
    assert_match(/,\s*5\s*\)/, generated)
  end

  private

  def demo_path
    File.expand_path("../../examples/milk-tea-demo.mt", __dir__)
  end

  def generate_c_from_source(source)
    Tempfile.create(["milk-tea-codegen", ".mt"]) do |file|
      file.write(source)
      file.flush

      program = MilkTea::ModuleLoader.check_program(file.path)
      MilkTea::Codegen.generate_c(program)
    end
  end

  def generate_c_from_program_source(source, imported_sources = {})
    Dir.mktmpdir("milk-tea-codegen") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, source)

      imported_sources.each do |relative_path, imported_source|
        path = File.join(dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, imported_source)
      end

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      MilkTea::Codegen.generate_c(program)
    end
  end
end
