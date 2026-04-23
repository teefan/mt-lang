# frozen_string_literal: true

require "fileutils"
require "tempfile"
require_relative "test_helper"

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
        "const TEN: i32 = 10",
        "",
        "def clamp[T](value: T, min_value: T, max_value: T) -> T:",
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
      "        let advanced = cast[ptr[byte]](memory) + 4",
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
      "def read(items: span[i32]) -> i32:",
      "    if items.len == 0:",
      "        return 0",
      "    unsafe:",
      "        return value(items.data)",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = span[i32](data = raw(addr(value)), len = 1)",
      "    return read(items)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_span_i32/, generated)
    assert_match(/int32_t \*data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static int32_t demo_span_surface_read\(mt_span_i32 items\)/, generated)
    assert_match(/if \(items\.len == 0\)/, generated)
    assert_match(/return \*items\.data;/, generated)
    assert_match(/mt_span_i32 items = \(mt_span_i32\)\{ \.data = \(\(int32_t\*\) \(&value\)\), \.len = 1 \};/, generated)
  end

  def test_generate_c_for_safe_span_indexing_and_element_assignment
    source = [
      "module demo.span_index_surface",
      "",
      "def bump(mut items: span[i32]) -> i32:",
      "    let first = items[0]",
      "    items[0] = first + 2",
      "    return items[0]",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = span[i32](data = raw(addr(value)), len = 1)",
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
      "def read(items: Slice[i32]) -> i32:",
      "    if items.len == 0:",
      "        return 0",
      "    unsafe:",
      "        return value(items.data)",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let holder = Holder(items = Slice[i32](data = raw(addr(value)), len = 1))",
      "    return read(holder.items)",
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
    assert_match(/static int32_t demo_generic_surface_read\(demo_generic_surface_Slice_i32 items\)/, generated)
    assert_match(/demo_generic_surface_Holder holder = \(demo_generic_surface_Holder\)\{ \.items = \(demo_generic_surface_Slice_i32\)\{ \.data = \(\(int32_t\*\) \(&value\)\), \.len = 1 \} \};/, generated)
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
      "    let items = Slice[i32](data = raw(addr(value)), len = 1)",
      "    let smallest = min(9, 4)",
      "    unsafe:",
      "        return value(head(items)) + smallest",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static int32_t\* demo_generic_functions_head_i32\(demo_generic_functions_Slice_i32 items\)/, generated)
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
      "    return cast[i32](total)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static uintptr_t demo_generic_layout_bytes_for_i32\(uintptr_t count\)/, generated)
    assert_match(/return count \* sizeof\(int32_t\);/, generated)
    assert_match(/uintptr_t total = demo_generic_layout_bytes_for_i32\(4\);/, generated)
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
    assert_match(/static void mt_panic\(const char\* message\)/, generated)
    assert_match(/static void mt_panic_str\(mt_str message\)/, generated)
    assert_match(/fputs\(message, stderr\);/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/abort\(\);/, generated)
    assert_match(/mt_panic_str\(\(mt_str\)\{ \.data = "bad state", \.len = 9 \}\);/, generated)
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

    assert_match(/while \(__mt_for_index_\d+ < 4\)/, generated)
    assert_match(/int32_t item = __mt_for_items_\d+\[__mt_for_index_\d+\];/, generated)
    assert_match(/while \(__mt_for_index_\d+ < __mt_for_stop_\d+\)/, generated)
    assert_match(/int32_t i = __mt_for_index_\d+;/, generated)
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
      "        value(target) += amount",
      "",
      "def main() -> i32:",
      "    var total = 0",
      "    for step in array[Step, 4](Step.keep, Step.skip, Step.keep, Step.stop):",
      "        defer add(raw(addr(total)), 1)",
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

    assert_match(/goto __mt_loop_continue_\d+;/, generated)
    assert_match(/goto __mt_loop_break_\d+;/, generated)
    assert_match(/__mt_loop_continue_\d+:;/, generated)
    assert_match(/__mt_loop_break_\d+:;/, generated)
    assert_match(/__mt_for_index_\d+ \+= 1;/, generated)
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
    assert_match(/const char\* data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static const mt_str demo_str_surface_greeting = \(mt_str\)\{ \.data = "hello", \.len = 5 \};/, generated)
    assert_match(/static void mt_panic_str\(mt_str message\) \{/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/mt_panic_str\(demo_str_surface_greeting\);/, generated)
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
      "    let counter_ptr = raw(addr(counter))",
      "    unsafe:",
      "        value(counter_ptr).value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_Counter \*counter_ptr = \(\(demo_pointer_surface_Counter\*\) \(&counter\)\);/, generated)
    assert_match(/\(\*counter_ptr\)\.value = 7;/, generated)
    assert_match(/return counter\.value;/, generated)
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
      "def increment(counter: ref[Counter], amount: i32) -> void:",
      "    value(counter).add(amount)",
      "    value(counter).value += 1",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let handle = addr(counter)",
      "    increment(handle, 4)",
      "    let value_ref = addr(value(handle).value)",
      "    value(value_ref) += 2",
      "    unsafe:",
      "        let raw_counter = raw(handle)",
      "        value(raw_counter).value += 1",
      "    return value(handle).value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static void demo_ref_surface_Counter_add\(demo_ref_surface_Counter \*this, int32_t delta\)/, generated)
    assert_match(/static void demo_ref_surface_increment\(demo_ref_surface_Counter \*counter, int32_t amount\)/, generated)
    assert_match(/demo_ref_surface_Counter \*handle = &counter;/, generated)
    assert_match(/demo_ref_surface_increment\(handle, 4\);/, generated)
    assert_match(/demo_ref_surface_Counter_add\(\&\(\*counter\), amount\);/, generated)
    assert_match(/\(\*counter\)\.value \+= 1;/, generated)
    assert_match(/int32_t \*value_ref = &\(\*handle\)\.value;/, generated)
    assert_match(/\*value_ref \+= 2;/, generated)
    assert_match(/demo_ref_surface_Counter \*raw_counter = \(\(demo_ref_surface_Counter\*\) handle\);/, generated)
    assert_match(/\(\*raw_counter\)\.value \+= 1;/, generated)
    assert_match(/return \(\*handle\)\.value;/, generated)
  end

  def test_generate_c_for_imported_associated_functions_on_type_aliases
    Dir.mktmpdir("milk-tea-codegen-associated") do |dir|
      FileUtils.mkdir_p(File.join(dir, "demo"))

      File.write(File.join(dir, "demo", "math.mt"), [
        "module demo.math",
        "",
        "struct RawVec:",
        "    x: i32",
        "",
        "type Vec = RawVec",
        "",
        "methods RawVec:",
        "    static def zero() -> Vec:",
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
      "        if value(raw(addr(palette[0]))) != 1:",
      "            return 1",
      "        if value(raw(addr(holder.colors[0]))) != 5:",
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

  def test_generate_c_for_array_assignment_and_parameter_copy
    source = [
      "module demo.array_copy_surface",
      "",
      "def mutate(mut values: array[i32, 4]) -> i32:",
      "    unsafe:",
      "        values[1] = 9",
      "        return values[1]",
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
    assert_match(/memcpy\(lhs, rhs, sizeof\(lhs\)\);/, generated)
    assert_match(/return \(\*mt_checked_index_array_i32_4\(\&\(values\), 1\)\);/, generated)
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
      "        let raw_buffer = raw(addr(buffer[0]))",
      "        set_text(cast[cstr](raw_buffer))",
      "        let clipboard = get_text()",
      "        let writable = cast[ptr[char]](clipboard)",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/set_text\(\(\(const char\*\) raw_buffer\)\);/, generated)
    assert_match(/char \*writable = \(\(char\*\) clipboard\);/, generated)
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
      "def read(counter: Counter) -> i32:",
      "    return counter.value",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 7)",
      "    let handle = addr(counter)",
      "    consume(value(handle))",
      "    return read(value(handle))",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/consume\(\*handle\);/, generated)
    assert_match(/return demo_ref_value_args_read\(\*handle\);/, generated)
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

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
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
