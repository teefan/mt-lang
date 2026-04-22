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
    assert_match(/static void demo_bouncing_ball_Ball_update\(demo_bouncing_ball_Ball \*self, float dt\)/, generated)
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
      "        return *items.data",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let items = span[i32](data = &value, len = 1)",
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
    assert_match(/mt_span_i32 items = \(mt_span_i32\)\{ \.data = &value, \.len = 1 \};/, generated)
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
      "        return *items.data",
      "",
      "def main() -> i32:",
      "    var value = 7",
      "    let holder = Holder(items = Slice[i32](data = &value, len = 1))",
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
      "    let items = Slice[i32](data = &value, len = 1)",
      "    let smallest = min(9, 4)",
      "    unsafe:",
      "        return *head(items) + smallest",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/static int32_t\* demo_generic_functions_head_i32\(demo_generic_functions_Slice_i32 items\)/, generated)
    assert_match(/static int32_t demo_generic_functions_min_i32\(int32_t a, int32_t b\)/, generated)
    assert_match(/int32_t smallest = demo_generic_functions_min_i32\(9, 4\);/, generated)
    assert_match(/return \(\*demo_generic_functions_head_i32\(items\)\) \+ smallest;/, generated)
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
    assert_match(/fputs\(message, stderr\);/, generated)
    assert_match(/abort\(\);/, generated)
    assert_match(/mt_panic\("bad state"\);/, generated)
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

  def test_generate_c_for_address_of_and_dereference_assignment
    source = [
      "module demo.pointer_surface",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = &counter",
      "    (*counter_ptr).value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/demo_pointer_surface_Counter \*counter_ptr = &counter;/, generated)
    assert_match(/\(\*counter_ptr\)\.value = 7;/, generated)
    assert_match(/return counter\.value;/, generated)
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
      "        if *cast[ptr[u32]](&palette) != 1:",
      "            return 1",
      "        if *cast[ptr[u32]](&holder.colors) != 5:",
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

  def test_generate_c_for_unsafe_array_indexing_and_assignment
    source = [
      "module demo.array_index_surface",
      "",
      "struct Palette:",
      "    colors: array[u32, 4]",
      "",
      "def main() -> i32:",
      "    var palette = array[u32, 4](1, 2, 3, 4)",
      "    var holder = Palette(colors = array[u32, 4](5, 6, 7, 8))",
      "    unsafe:",
      "        palette[1] = 9",
      "        holder.colors[2] = 10",
      "        if palette[0] != 1:",
      "            return 1",
      "        if holder.colors[2] != 10:",
      "            return 2",
      "    return 0",
      "",
    ].join("\n")

    generated = generate_c_from_source(source)

    assert_match(/palette\[1\] = 9;/, generated)
    assert_match(/holder\.colors\[2\] = 10;/, generated)
    assert_match(/if \(palette\[0\] != 1\)/, generated)
    assert_match(/if \(holder\.colors\[2\] != 10\)/, generated)
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
    assert_match(/int32_t values\[4\];\n  memcpy\(values, values_input, sizeof\(values\)\);/, generated)
    assert_match(/memcpy\(lhs, rhs, sizeof\(lhs\)\);/, generated)
    assert_match(/return values\[1\];/, generated)
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
end
