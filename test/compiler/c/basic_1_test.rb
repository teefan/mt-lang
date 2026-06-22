# frozen_string_literal: true

require_relative "helpers"

class Basic1Test < Minitest::Test
  include CodegenTestHelpers

  def test_generate_c_for_attribute_reflection_static_asserts
    source = <<~MT
      # module demo.attribute_reflection_codegen

      public attribute[field] rename(name: str)
      public attribute[callable] traced(name: str)

      @[packed]
      struct PacketHeader:
          @[rename("payload_len")]
          payload_len: uint
          flag_bits: ubyte

      @[align(16)]
      struct PacketBuffer:
          data: array[ubyte, 16]

      @[traced("parse_packet")]
      function parse_packet() -> int:
          return 7

      static_assert(has_attribute(PacketHeader, packed), "PacketHeader should stay packed")
      static_assert(
          has_attribute(PacketBuffer, align) and attribute_arg[ptr_uint](attribute_of(PacketBuffer, align), bytes) == 16,
          "PacketBuffer should stay 16-byte aligned"
      )
      static_assert(has_attribute(field_of(PacketHeader, payload_len), rename), "payload_len rename missing")
      static_assert(has_attribute(callable_of(parse_packet), traced), "parse_packet trace missing")

      function aligned_bytes() -> ptr_uint:
          if has_attribute(PacketBuffer, align):
              return attribute_arg[ptr_uint](attribute_of(PacketBuffer, align), bytes)
          return 0

      function main() -> int:
          return parse_packet() + int<-aligned_bytes()
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/packed/, generated)
    assert_match(/aligned\(16\)/, generated)
    assert_match(/PacketHeader should stay packed/, generated)
    assert_match(/PacketBuffer should stay 16-byte aligned/, generated)
    assert_match(/payload_len rename missing/, generated)
    assert_match(/parse_packet trace missing/, generated)
    assert_match(/return 16;/, generated)
  end

  def test_generate_c_for_external_struct_with_explicit_c_name
    source = <<~MT
      # module demo.timespec_codegen

      import std.c.time as c

      function main() -> int:
          var duration = c.timespec(tv_sec = 1, tv_nsec = 2)
          return c.nanosleep(ptr_of(duration), null)
    MT

    imported_sources = {
      "std/c/time.mt" => <<~MT,
        # module std.c.time
        external
        include "time.h"

        opaque tm = c"struct tm"

        struct timespec = c"struct timespec":
            tv_sec: ptr_int
            tv_nsec: ptr_int

        external function nanosleep(duration: const_ptr[timespec], remaining: ptr[timespec]?) -> int
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/#include <time\.h>/, generated)
    assert_match(/struct timespec duration = \{ \.tv_sec = 1, \.tv_nsec = 2 \};/, generated)
    assert_match(/return nanosleep\(&duration, NULL\);/, generated)
  end

    def test_generate_c_for_local_enums_flags_and_unions
      source = <<~MT

# module demo.codegen_surface

enum State: int
    idle = 0
    running = 1

flags WindowFlags: uint
    visible = 1 << 0
    resizable = 1 << 1

union Payload:
    count: int
    enabled: bool

const DEFAULT_STATE: State = State.idle
const DEFAULT_FLAGS: WindowFlags = WindowFlags.visible | WindowFlags.resizable

function pick_state(active: bool) -> State:
    if active:
        return State.running
    return DEFAULT_STATE

function main() -> int:
    let current = pick_state(true)
    if current == State.running:
        return 1
    return 0

      MT

    generated = generate_c_from_program_source(source)

    assert_match(/typedef int32_t demo_codegen_surface_State;/, generated)
    assert_match(/demo_codegen_surface_State_idle = 0/, generated)
    assert_match(/demo_codegen_surface_State_running = 1/, generated)
    assert_match(/typedef uint32_t demo_codegen_surface_WindowFlags;/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_visible = 1 << 0/, generated)
    assert_match(/demo_codegen_surface_WindowFlags_resizable = 1 << 1/, generated)
    assert_match(/typedef union demo_codegen_surface_Payload/, generated)
    assert_match(/static const demo_codegen_surface_State demo_codegen_surface_DEFAULT_STATE = demo_codegen_surface_State_idle;/, generated)
    assert_match(/static const demo_codegen_surface_WindowFlags demo_codegen_surface_DEFAULT_FLAGS = demo_codegen_surface_WindowFlags_visible \| demo_codegen_surface_WindowFlags_resizable;/, generated)
    assert_match(/if \(\(int32_t\) current == \(int32_t\) demo_codegen_surface_State_running\)/, generated)
    assert_match(/return 1;/, generated)
    end

  def test_generate_c_includes_imported_ordinary_module_definitions
    Dir.mktmpdir("milk-tea-codegen-imports") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      FileUtils.mkdir_p(File.join(dir, "demo"))

      File.write(File.join(dir, "std", "math.mt"), <<~MT

# module std.math

public const TEN: int = 10
public const UNUSED: int = 99

public function clamp[T](value: T, min_value: T, max_value: T) -> T:
    if value < min_value:
        return min_value
    else if value > max_value:
        return max_value
    return value

      MT

      )
      root_path = File.join(dir, "demo", "main.mt")
      File.write(root_path, <<~MT

# module demo.main

import std.math as math

function main() -> int:
    return math.clamp(42, 0, math.TEN)

      MT

      )
      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(root_path)
      generated = MilkTea::Codegen.generate_c(MilkTea::Lowering.lower(program))

      assert_match(/static const int32_t std_math_TEN = 10;/, generated)
      refute_match(/static const int32_t std_math_UNUSED = 99;/, generated)
      assert_match(/static int32_t std_math_clamp_int\(int32_t value, int32_t min_value, int32_t max_value\)/, generated)
      assert_match(/return std_math_clamp_int\(42, 0, std_math_TEN\);/, generated)
    end
  end

  def test_generate_c_uses_trailing_underscore_field_name
    source = <<~MT
      # module demo.extern_field_alias

      import std.c.sample as c

      function is_quit(event_: c.Event) -> bool:
          return event_.type_ == uint<-(int<-c.EventType.QUIT)
    MT

    imported = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        enum EventType: int
            QUIT = 256
        union Event:
            type_: uint
      MT
    }

    generated = generate_c_from_program_source(source, imported)

    assert_match(/event\.type/, generated)
    refute_match(/event\.type_/, generated)
  end

  def test_generate_c_for_unsafe_pointer_cast_and_arithmetic
    source = <<~MT

# module demo.pointer_surface

external function allocate(size: ptr_uint) -> ptr[void]
external function release(memory: ptr[void]) -> void

function main() -> int:
    let memory = allocate(16)
    unsafe:
        let advanced = ptr[ubyte]<-memory + 4
    release(memory)
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/uint8_t \*advanced = \(uint8_t\*\) memory \+ 4;/, generated)
    assert_match(/release\(memory\);/, generated)
  end

  def test_generate_c_for_span_construction_and_field_access
    source = <<~MT

# module demo.span_surface

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

    generated = generate_c_from_source(source)

    assert_match(/typedef struct mt_span_int/, generated)
    assert_match(/int32_t \*data;/, generated)
    assert_match(/uintptr_t len;/, generated)
    assert_match(/static int32_t demo_span_surface_first\(mt_span_int items\)/, generated)
    assert_match(/if \(items\.len == 0\)/, generated)
    assert_match(/return \*items\.data;/, generated)
    assert_match(/mt_span_int items = \{ \.data = &value, \.len = 1 \};/, generated)
  end

  def test_generate_c_emits_line_directives_for_user_statements
    source = <<~MT
      # module demo.line_directives

      function main() -> int:
          let x: int = 1
          return x
    MT

    generated = generate_c_from_source(source)

    assert_match(/#line \d+ ".*\.mt"/, generated)
  end

  def test_generate_c_emits_line_directives_in_nested_blocks
    source = <<~MT
      # module demo.line_directives_2

      function nested_test(flag: bool) -> int:
          if flag:
              let x: int = 1
              return x
          else:
              let y: int = 2
              return y
    MT

    generated = generate_c_from_source(source)
    line_directives = generated.scan(/#line \d+/)
    assert_operator line_directives.length, :>, 2, "expected multiple #line directives for nested blocks"
  end

  def test_generate_c_emits_line_directives_with_module_source
    source = <<~MT
      # module demo.line_directives_3

      function source_trace(limit: int) -> int:
          var total: int = 0
          var i: int = 0
          while i < limit:
              total += i
              i += 1
          return total
    MT

    generated = generate_c_from_source(source)
    assert_match(/#line \d+ ".*line_directives_3\.mt"/, generated)
    assert_match(/#line \d+ ".*\.mt"/, generated)
  end

  def test_generate_c_debug_profile_includes_line_directives
    source = <<~MT
      # module demo.debug_profile

      function mul(a: int, b: int) -> int:
          let product = a * b
          return product
    MT

    generated = generate_c_from_source(source)
    assert_match(/#line \d+ ".*\.mt"/, generated)
  end

  def test_generate_c_for_loop_over_custom_iterator_protocol
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

    generated = generate_c_from_source(source)

    assert_match(/static demo_iterator_for_NumbersIter demo_iterator_for_Numbers_iter\(demo_iterator_for_Numbers this\)/, generated)
    assert_match(/static int32_t\s*\*\s*demo_iterator_for_NumbersIter_next\(demo_iterator_for_NumbersIter \*this\)/, generated)
    assert_match(/demo_iterator_for_NumbersIter_next\(&[A-Za-z0-9_]+\)/, generated)
    assert_match(/if \([A-Za-z0-9_]+ == NULL\)/, generated)
    assert_match(/total \+= \*[A-Za-z0-9_]+;/, generated)
  end

  def test_generate_c_for_loop_over_bool_current_iterator_protocol
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

    generated = generate_c_from_source(source)

    assert_match(/static bool demo_iterator_current_NumbersIter_next\(demo_iterator_current_NumbersIter \*this\)/, generated)
    assert_match(/static int32_t demo_iterator_current_NumbersIter_current\(demo_iterator_current_NumbersIter this\)/, generated)
    assert_match(/demo_iterator_current_NumbersIter_current\([A-Za-z0-9_]+\)/, generated)
    assert_match(/while \([A-Za-z0-9_]+\([^)]*\)\) \{/, generated)
    assert_match(/total \+= value;/, generated)
  end

  def test_generate_c_struct_span_for_loop_as_mutable_alias
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

    generated = generate_c_from_source(source)

    assert_match(/demo_for_ref_Position \*item = &__mt_for_items_[A-Za-z0-9_]+\.data\[__mt_for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/item->x \+= 1;/, generated)
    assert_match(/item->y \+= 2;/, generated)
  end

  def test_generate_c_parallel_collection_for_loop
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

    generated = generate_c_from_source(source)

    assert_match(/if \(__mt_for_items_[A-Za-z0-9_]+\.len != __mt_for_items_[A-Za-z0-9_]+\.len\)/, generated)
    assert_match(/int32_t entity = __mt_for_items_[A-Za-z0-9_]+\.data\[__mt_for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/demo_parallel_for_Position \*position = &__mt_for_items_[A-Za-z0-9_]+\.data\[__mt_for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/demo_parallel_for_Velocity \*velocity = &__mt_for_items_[A-Za-z0-9_]+\.data\[__mt_for_index_[A-Za-z0-9_]+\];/, generated)
    assert_match(/position->x \+= velocity->x;/, generated)
    assert_match(/position->y \+= velocity->y;/, generated)
  end

  def test_generate_c_keeps_omitted_receiver_wrapper_for_side_effectful_receiver_expression
    source = <<~MT
      # module demo.side_effectful_receiver_codegen

      struct Box:
          value: int

      extending Box:
          static function build() -> Box:
              return Box(value = 1)

          function echo[T](input: T) -> T:
              return input

      function main() -> int:
          if Box.build().echo(true):
              return 1
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/demo_side_effectful_receiver_codegen_Box_build_static\(\)/, generated)
    assert_match(/if \(\(\(void\)demo_side_effectful_receiver_codegen_Box_build_static\(\), demo_side_effectful_receiver_codegen_Box_echo_bool\(true\)\)\) \{/, generated)
  end

  def test_generate_c_emits_declaration_for_unused_parameters
    source = <<~MT
      # module demo.unused_params_codegen

      interface Runner:
          function tick(effect: int) -> int

      struct Title implements Runner:
          value: int

      extending Title:
          function tick(effect: int) -> int:
              return this.value

      function main() -> int:
          let title = Title(value = 3)
          return title.tick(7)
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/static int32_t demo_unused_params_codegen_Title_tick\(demo_unused_params_codegen_Title this, int32_t effect\)/, generated)
    refute_match(/\(void\)effect/, generated)
  end

  def test_generate_c_for_if_else_if_else_emits_flat_chain
    source = <<~MT
      # module demo.if_chain_codegen

      function classify(value: int) -> int:
          if value < 0:
              return -1
          else if value > 0:
              return 1
          else:
              return 0
    MT

    generated = generate_c_from_program_source(source)
    function_body = generated[/static int32_t demo_if_chain_codegen_classify\(.*?^\}/m]

    refute_nil function_body
    assert_match(/\} else if \(/, function_body)
    refute_match(/\} else \{\n\s+if \(/, function_body)
  end

  def test_generate_c_for_foreign_defs_with_out_and_automatic_cstr_temps
    source = <<~MT
      # module demo.main

      import std.raylib as rl

      function main(path: str, data: span[ubyte]) -> int:
          var data_size = 0
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

        external function LoadFileData(file_name: cstr, data_size: ptr[int]) -> ptr[ubyte]?
        external function SaveFileData(file_name: cstr, data: ptr[ubyte], bytes: int) -> bool
      MT
      "std/raylib.mt" => <<~MT,
        # module std.raylib

        import std.c.raylib as c

        public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData
        public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)
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
      # module demo.main

      import std.sample as sample

      function main(path: str) -> int:
          let first = sample.load(path)
          var second = 0
          second = sample.load(path)
          return first + second
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Load(path: cstr) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function load(path: str as cstr) -> int = c.Load
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_result_\d+/, generated)
    assert_match(/int32_t first = Load\(__mt_foreign_arg_\d+\);/, generated)
    assert_match(/second = Load\(__mt_foreign_arg_\d+\);/, generated)
    assert_match(/mt_free_foreign_cstr_temp\(__mt_foreign_arg_\d+\);/, generated)
  end

  def test_generate_c_for_variadic_foreign_str_arguments
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(path: str, count: int) -> int:
          sample.print("path=%s count=%d\\n", path, count)
          return 0
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        include "stdio.h"

        external function printf(format: cstr, ...) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function print(format: str as cstr, ...) -> int = c.printf
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_str_to_cstr_temp/, generated)
    assert_match(/printf\("path=%s count=%d\\n", __mt_foreign_arg_\d+, count\);/, generated)
    assert_match(/mt_free_foreign_cstr_temp\(__mt_foreign_arg_\d+\);/, generated)
  end

  def test_generate_c_for_std_fmt_format_literals
    source = <<~MT
      # module demo.format_codegen

      import std.fmt as fmt
      import std.string as string

      function main(value: ubyte, delta: short, ticks: ulong, raw: cstr) -> int:
          let text = fmt.format(f"value=\#{value} delta=\#{delta} ticks=\#{ticks} raw=\#{raw} ok=\#{true}")
          return int<-text.len()
    MT

    generated = generate_c_from_source(source)

    refute_match(/demo_format_codegen__fmt_\d+/, generated)
    assert_match(/mt_str __fmt_\w+ = mt_format_str_make\(__fmt_\w+_cap\);/, generated)
    assert_match(/std_string_String text = std_fmt_format\(__fmt_\w+\);/, generated)
    assert_match(/mt_format_str_release\(__fmt_\w+\);/, generated)
    assert_match(/uintptr_t __fmt_\w+_cap = 29;/, generated)
    assert_match(/mt_format_append_uint\(/, generated)
    assert_match(/mt_format_append_int\(/, generated)
    assert_match(/mt_format_append_ulong\(/, generated)
    assert_match(/mt_format_append_cstr\(/, generated)
    assert_match(/mt_format_append_bool\(/, generated)
    refute_match(/std_fmt_append\(/, generated)
  end

  def test_generate_c_for_general_format_string_expressions
    source = <<~MT
      # module demo.format_expr_codegen

      function sink(text: str) -> ptr_uint:
          return text.len

      function main(value: ubyte, delta: short) -> int:
          let text = f"value=\#{value} delta=\#{delta}"
          if sink(f"ok=\#{true}") == 0:
              return 1
          return int<-text.len
    MT

    generated = generate_c_from_source(source)

    refute_match(/demo_format_expr_codegen__fmt_\d+/, generated)
    assert_match(/__fmt_\w+ = mt_format_str_make\(__fmt_\w+_cap\);/, generated)
    assert_match(/mt_str text = __fmt_\w+;/, generated)
    assert_match(/demo_format_expr_codegen_sink\(__fmt_\w+\)/, generated)
    assert_operator generated.scan(/mt_format_str_release\(__fmt_\w+\);/).length, :>=, 2
    assert_match(/mt_format_str_release\(__fmt_\w+\);/, generated)
  end

  def test_generate_c_for_direct_string_sink_format_literals
    source = <<~MT
      # module demo.format_sink_codegen

      import std.string as string

      function main(value: int) -> int:
          var output = string.String.create()
          defer output.release()
          output.assign(f"value=\#{value}")
          output.append(f" ok=\#{true}")
          return int<-output.len()
    MT

    generated = generate_c_from_source(source)

    refute_match(/demo_format_sink_codegen__fmt_\d+/, generated)
    assert_match(/std_string_String_assign\(&output, __fmt_\w+\);/, generated)
    assert_match(/std_string_String_append\(&output, __fmt_\w+\);/, generated)
    assert_equal 2, generated.scan(/mt_format_str_release\(__fmt_\w+\);/).length
  end

  def test_generate_c_for_explicit_builder_format_sinks
    source = <<~MT
      # module demo.explicit_format_sink_codegen

      import std.fmt as fmt
      import std.string as string

      function main(value: uint, ratio: double, raw: cstr) -> int:
          var output = string.String.create()
          defer output.release()
          fmt.append_format(ref_of(output), f"hex=\#{value:x} raw=\#{raw}")
          output.assign_format(f"ratio=\#{ratio:.2} ok=\#{true}")
          return int<-output.len()
    MT

    generated = generate_c_from_source(source)

    refute_match(/mt_str __mt_fmt_string_\d+ = mt_format_str_make/, generated)
    refute_match(/std_fmt_append_format\(/, generated)
    refute_match(/std_string_String_append_format\(/, generated)
    assert_match(/std_string_String_append\(&output, /, generated)
    assert_match(/std_fmt_append_ulong_hex\(&output, /, generated)
    assert_match(/std_fmt_append_cstr\(&output, /, generated)
    assert_match(/std_string_String_clear\(&output\);/, generated)
    assert_match(/std_fmt_append_double_precision\(&output, /, generated)
    assert_match(/std_fmt_append_bool\(&output, /, generated)
  end

  def test_generate_c_inlines_identical_format_string_builders_without_helpers
    source = <<~MT
      # module demo.format_dedup_codegen

      function first(value: ubyte) -> ptr_uint:
          let text = f"value=\#{value} ok=\#{true}"
          return text.len

      function second(value: ubyte) -> ptr_uint:
          let text = f"value=\#{value} ok=\#{true}"
          return text.len
    MT

    generated = generate_c_from_source(source)

    refute_match(/demo_format_dedup_codegen__fmt_\d+/, generated)
    assert_equal 2, generated.scan(/__fmt_\w+ = mt_format_str_make\(__fmt_\w+_cap\)/).length
  end

  def test_rejects_returning_general_format_string_as_borrowed_text
    source = <<~MT
      # module demo.format_expr_escape

      function main(value: int) -> str:
          return f"value=\#{value}"
    MT

    error = assert_raises(MilkTea::LoweringError) do
      generate_c_from_source(source)
    end

    assert_match(/formatted string temporaries cannot be returned as borrowed text/, error.message)
  end

  def test_generate_c_for_cstr_backed_string_constants_without_foreign_temps
    source = <<~MT
      # module demo.main

      import std.sample as sample

      const PATH: str = "demo.txt"

      function main() -> int:
          return sample.load(PATH)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Load(path: cstr) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function load(path: str as cstr) -> int = c.Load
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_foreign_str_to_cstr_temp/, generated)
    refute_match(/mt_free_foreign_cstr_temp/, generated)
    assert_match(/return Load\(\(const char\*\) demo_main_PATH\.data\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_in_const_void_pointer
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          let value = 7
          sample.inspect(value)
          sample.inspect(value + 1)
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/Inspect\(\(const void\*\) &value\);/, generated)
    assert_match(/int32_t __mt_foreign_in_\d+ = value \+ 1;/, generated)
    assert_match(/Inspect\(\(const void\*\) &__mt_foreign_in_\d+\);/, generated)
  end

  def test_generate_c_for_external_out_params
    source = <<~MT
      # module demo.external_out_surface

      external function Fill(out value: int, inout total: int) -> void

      function main() -> int:
          var value = 1
          var total = 2
          Fill(value, total)
          return value + total
    MT

    generated = generate_c_from_source(source)

    assert_match(/Fill\(&value, &total\);/, generated)
  end

  def test_generate_c_for_local_const_ptr_typed_binding
    source = <<~MT
      # module demo.main

      function main() -> void:
          let value = 7
          let pointer: const_ptr[int] = const_ptr_of(value)
          let copy: const_ptr[int] = pointer
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/const int32_t\* pointer = &value;/, generated)
    assert_match(/const int32_t\* copy = pointer;/, generated)
  end

  def test_generate_c_escapes_local_names_that_match_c_keywords
    source = <<~MT
      # module demo.main

      function main() -> int:
          let times_two = 7
          return times_two + 1
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/int32_t times_two = 7;/, generated)
    assert_match(/return times_two \+ 1;/, generated)
  end

  def test_generate_c_for_foreign_defs_with_string_literal_without_using_scratch
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/Arena_mark\(/, generated)
    refute_match(/Arena_reset\(/, generated)
    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/InitWindow\(800, 450, "Demo"\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_span_str_to_span_cstr_boundary
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[str, 3]("Play", "Options", "Quit")
          var active = 1
          return sample.use_names(labels, active)
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

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    refute_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/const char\* __mt_foreign_cstr_items_\d+\[3\] = \{ \(const char\*\) labels\[0\]\.data, \(const char\*\) labels\[1\]\.data, \(const char\*\) labels\[2\]\.data \};/, generated)
    assert_match(/__mt_foreign_arg_\d+\.data/, generated)
    assert_match(/\(\(int32_t\) __mt_foreign_arg_\d+\.len\)|\(int32_t\) __mt_foreign_arg_\d+\.len/, generated)
  end

  def test_generate_c_for_foreign_defs_with_span_str_to_span_ptr_char_boundary
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function middle() -> str:
          return "Options"

      function main() -> int:
          var labels = array[str, 3]("Play", middle(), "Quit")
          var active = 1
          return sample.use_names(labels, active)
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/__mt_foreign_arg_\d+\.data/, generated)
    assert_match(/\(\(int32_t\) __mt_foreign_arg_\d+\.len\)|\(int32_t\) __mt_foreign_arg_\d+\.len/, generated)
  end

  def test_generate_c_for_ignored_foreign_result_with_span_str_temp_marshalling
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function middle() -> str:
          return "Options"

      function main() -> int:
          var labels = array[str, 3]("Play", middle(), "Quit")
          var active = 1
          sample.use_names(labels, active)
          return active
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    assert_match(/UseNames\(/, generated)
    refute_match(/__mt_foreign_result_\d+/, generated)
  end

  def test_generate_c_for_nested_foreign_defs_in_inline_contexts
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function middle() -> str:
          return "34"

      function keep(value: int) -> int:
          return value

      function main() -> int:
          var labels = array[str, 3]("12", middle(), "56")
          let counted = keep(sample.count_names(labels))
          let doubled = keep(sample.pair_sum(1 + 2))
          return counted + doubled
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/mt_foreign_strs_to_cstrs_temp/, generated)
    assert_match(/mt_free_foreign_cstrs_temp/, generated)
    refute_match(/__mt_foreign_expr_\d+/, generated)
    refute_match(/int32_t __mt_foreign_arg_\d+ = 1 \+ 2;/, generated)
    assert_match(/int32_t doubled = demo_main_keep\(PairSum\(1 \+ 2, 1 \+ 2\)\);/, generated)
    assert_match(/CountNames\(/, generated)
    assert_match(/PairSum\(/, generated)
  end

  def test_generate_c_for_foreign_mapping_call_member_access
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          return sample.project(7)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Pair:
            value: int

        external function MakePair(value: int) -> Pair
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function project(value: int) -> int = c.MakePair(value).value
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/return \(MakePair\(7\)\)\.value;/, generated)
  end

  def test_rejects_codegen_for_foreign_defs_with_str_to_ptr_char_boundary
    source = <<~MT
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
      generate_c_from_program_source(source, imported_sources)
    end

    assert_match(/cannot map str as ptr\[char\]/, error.message)
  end

  def test_generate_c_for_foreign_defs_with_span_cstr_to_span_ptr_char_without_scratch
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var labels = array[cstr, 3]("Play", "Options", "Quit")
          var active = 1
          return sample.use_names(labels, active)
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/typedef struct mt_span_cstr \{/, generated)
    assert_match(/const char\* labels\[3\] = \{ "Play", "Options", "Quit" \};/, generated)
    refute_match(/std_mem_arena_Arena_to_char_ptrs\(/, generated)
    refute_match(/std_mem_arena_Arena_to_cstrs\(/, generated)
    assert_match(/UseNames\(/, generated)
    assert_match(/&labels\[0\]/, generated)
    assert_match(/&active/, generated)
  end

  def test_generate_c_for_foreign_defs_with_nullable_pointer_inout_slot
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> int:
          var state: ptr[char]? = null
          let token = sample.next_token(null[ptr[char]], c",", state)
          return if token == null: 0 else: 1
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function NextToken(text: ptr[char]?, delim: cstr, state: ptr[ptr[char]]) -> ptr[char]?
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function next_token(text: ptr[char]?, delim: cstr, inout state: ptr[char]?) -> ptr[char]? = c.NextToken(text, delim, state)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/NextToken\(/, generated)
    assert_match(/&state/, generated)
  end

  def test_generate_c_for_contextual_string_literals_as_cstr
    source = <<~MT
      # module demo.literal_cstr

      external function set_text(value: cstr) -> void

      function main() -> cstr:
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
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var camera = sample.Camera(id = 1)
          sample.update_camera(camera, sample.CameraMode.CAMERA_FREE)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Camera:
            id: int

        enum CameraMode: int
            CAMERA_FREE = 1

        external function UpdateCamera(camera: ptr[Camera], mode: CameraMode) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public type Camera = c.Camera
        public type CameraMode = c.CameraMode

        public foreign function update_camera(inout camera: Camera, mode: CameraMode) -> void = c.UpdateCamera
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/UpdateCamera\(&camera, CAMERA_FREE\);/, generated)
    refute_match(/UpdateCamera\(\(\([A-Za-z_][A-Za-z0-9_]*\*\) \(&camera\)\), CAMERA_FREE\);/, generated)
  end

  def test_generate_c_for_imported_inout_call_inside_editable_method_uses_receiver_pointer
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main() -> void:
          var camera = sample.Camera(id = 1)
          camera.update(sample.CameraMode.CAMERA_FREE)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Camera:
            id: int

        enum CameraMode: int
            CAMERA_FREE = 1

        external function UpdateCamera(camera: ptr[Camera], mode: CameraMode) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public type Camera = c.Camera
        public type CameraMode = c.CameraMode

        public foreign function update_camera(inout camera: Camera, mode: CameraMode) -> void = c.UpdateCamera

        extending Camera:
            public editable function update(mode: CameraMode) -> void:
                update_camera(this, mode)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/static void Camera_update\(Camera \*this, CameraMode mode\)/, generated)
    assert_match(/UpdateCamera\([^\n]*this[^\n]*, mode\);/, generated)
    refute_match(/UpdateCamera\(&this, mode\);/, generated)
  end

  def test_generate_c_for_foreign_defs_without_temps_for_simple_statement_arguments
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(center: float) -> void:
          sample.draw_triangle(
              sample.Vector2(x = center, y = 80.0),
              sample.Vector2(x = center - 60.0, y = 150.0),
              sample.Vector2(x = center + 60.0, y = 150.0),
              sample.VIOLET,
          )
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Vector2:
            x: float
            y: float

        struct Color:
            r: ubyte
            g: ubyte
            b: ubyte
            a: ubyte

        const VIOLET: Color = Color(r = 200, g = 122, b = 255, a = 255)

        external function DrawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, color: Color) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public type Vector2 = c.Vector2
        public type Color = c.Color
        public const VIOLET: Color = c.VIOLET

        public foreign function draw_triangle(v1: Vector2, v2: Vector2, v3: Vector2, color: Color) -> void = c.DrawTriangle
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/DrawTriangle\(\(Vector2\)\{ \.x = center, \.y = 80\.0f \}, \(Vector2\)\{ \.x = center - 60\.0f, \.y = 150\.0f \}, \(Vector2\)\{ \.x = center \+ 60\.0f, \.y = 150\.0f \}, std_sample_VIOLET\);/, generated)
  end

  def test_generate_c_for_checked_span_index_foreign_arguments_without_foreign_arg_temps
    source = <<~MT
      # module demo.main

      import std.sample as sample

      struct Bunny:
          x: int
          y: int
          color: int

      function main(items: span[Bunny], count: int) -> void:
          for index in 0..count:
              sample.draw(items[index].x, items[index].y, items[index].color)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        external function Draw(x: int, y: int, color: int) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function draw(x: int, y: int, color: int) -> void = c.Draw
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
      # module demo.main

      import std.sample as sample

      function main() -> void:
          sample.use_color(sample.fade(sample.RED, 0.5))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        struct Color:
            r: ubyte
            g: ubyte
            b: ubyte
            a: ubyte

        const RED: Color = Color(r = 255, g = 0, b = 0, a = 255)

        external function Fade(color: Color, alpha: float) -> Color
        external function UseColor(color: Color) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public type Color = c.Color
        public const RED: Color = c.RED

        public foreign function fade(color: Color, alpha: float) -> Color = c.Fade
        public foreign function use_color(color: Color) -> void = c.UseColor
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/UseColor\(Fade\(std_sample_RED, 0\.5f\)\);/, generated)
  end

  def test_generate_c_for_foreign_text_calls_without_numbered_argument_temps
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(area: int) -> void:
          let label = "COLLISION!"
          sample.draw_text(label, sample.screen_width() / 2 - sample.measure_text(label, 20) / 2, 10, 20, sample.BLACK)
          sample.draw_text(sample.text_format_int("Collision Area: %i", area), sample.screen_width() / 2 - 100, 20, 20, sample.BLACK)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        const BLACK: int = 0

        external function DrawText(text: cstr, pos_x: int, pos_y: int, font_size: int, color: int) -> void
        external function MeasureText(text: cstr, font_size: int) -> int
        external function GetScreenWidth() -> int
        external function TextFormat(format: cstr, value: int) -> cstr
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public const BLACK: int = c.BLACK

        public foreign function draw_text(text: str as cstr, pos_x: int, pos_y: int, font_size: int, color: int) -> void = c.DrawText
        public foreign function measure_text(text: str as cstr, font_size: int) -> int = c.MeasureText
        public foreign function screen_width() -> int = c.GetScreenWidth
        public foreign function text_format_int(format: str as cstr, value: int) -> cstr = c.TextFormat(format, value)
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/DrawText\(\(const char\*\) label\.data, GetScreenWidth\(\) \/ 2 - MeasureText\(\(const char\*\) label\.data, 20\) \/ 2, 10, 20, std_sample_BLACK\);/, generated)
    assert_match(/DrawText\(TextFormat\("Collision Area: %i", area\), GetScreenWidth\(\) \/ 2 - 100, 20, 20, std_sample_BLACK\);/, generated)
  end

  def test_generate_c_for_foreign_text_calls_with_dynamic_format_literals_without_extra_cstr_copy
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function main(score: int) -> void:
          sample.draw_text(f"Score  \#{score}", 10, 20, 20, sample.BLACK)
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external
        const BLACK: int = 0

        external function DrawText(text: cstr, pos_x: int, pos_y: int, font_size: int, color: int) -> void
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public const BLACK: int = c.BLACK

        public foreign function draw_text(text: str as cstr, pos_x: int, pos_y: int, font_size: int, color: int) -> void = c.DrawText
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/demo_main__fmt_\d+/, generated)
    assert_match(/\w+ = mt_format_str_make\(\w+_cap\);/, generated)
    assert_match(/DrawText\(\(const char\*\) \w+\.data, 10, 20, 20, std_sample_BLACK\);/, generated)
    assert_match(/mt_format_str_release\(\w+\);/, generated)
    refute_match(/mt_foreign_str_to_cstr_temp/, generated)
    refute_match(/mt_free_foreign_cstr_temp/, generated)
  end

  def test_generate_c_for_variadic_foreign_mapping_calls
    source = <<~MT
      # module demo.variadic_foreign

      import std.stdio as stdio

      function main() -> int:
          var buffer = zero[array[char, 64]]
          stdio.print_format("ok=%d\\n", 1)
          stdio.str_format_bounded(ptr_of(buffer[0]), 64, "n=%d", 7)
          return 0
    MT

    generated = generate_c_from_source(source)

    assert_match(/printf\("ok=%d\\n", 1\);/, generated)
    assert_match(/snprintf\([^\n]*"n=%d", 7\);/, generated)
  end

  def test_generate_c_for_nested_variadic_foreign_text_calls_inside_ordinary_calls
    source = <<~MT
      # module demo.main

      import std.sample as sample

      function measure(text: cstr) -> int:
          return sample.measure_text(text, 20)

      function particle_type_name(kind: int) -> str:
          if kind == 0:
              return "WATER"
          return "FIRE"

      function main(kind: int) -> int:
          return measure(sample.text_format("%s", particle_type_name(kind)))
    MT

    imported_sources = {
      "std/c/sample.mt" => <<~MT,
        # module std.c.sample
        external

        external function TextFormat(format: cstr, ...) -> cstr
        external function MeasureText(text: cstr, font_size: int) -> int
      MT
      "std/sample.mt" => <<~MT,
        # module std.sample

        import std.c.sample as c

        public foreign function text_format(format: str as cstr, ...) -> cstr = c.TextFormat
        public foreign function measure_text(text: cstr, font_size: int) -> int = c.MeasureText
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/const char\* __mt_foreign_arg_\d+ = mt_foreign_str_to_cstr_temp\(/, generated)
    assert_match(/const char\* __mt_foreign_result_\d+ = TextFormat\("%s", __mt_foreign_arg_\d+\);/, generated)
    assert_match(/mt_free_foreign_cstr_temp\(__mt_foreign_arg_\d+\);/, generated)
    assert_match(/return demo_main_measure\(__mt_foreign_result_\d+\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_identity_pointer_projections
    source = <<~MT
      # module demo.main

      import std.mem as mem

      function first_byte() -> ubyte:
          unsafe:
              return mem.allocate_bytes(16)[0]

      function main(buffer: ptr[char]) -> ubyte:
          mem.release_bytes(mem.allocate_bytes(8))
          mem.set_label(buffer)
          return first_byte()
    MT

    imported_sources = {
      "std/c/mem.mt" => <<~MT,
        # module std.c.mem
        external
        include "mem.h"

        external function AllocateBytes(size: ptr_uint) -> ptr[void]
        external function ReleaseBytes(memory: ptr[void]) -> void
        external function SetLabel(label: cstr) -> void
      MT
      "std/mem.mt" => <<~MT,
        # module std.mem

        import std.c.mem as c

        public foreign function allocate_bytes(size: ptr_uint) -> ptr[ubyte] = c.AllocateBytes
        public foreign function release_bytes(memory: ptr[ubyte]) -> void = c.ReleaseBytes
        public foreign function set_label(label: ptr[char]) -> void = c.SetLabel
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/return \(\(uint8_t\*\) AllocateBytes\(16\)\)\[0\];/, generated)
    refute_match(/__mt_foreign_arg_\d+/, generated)
    assert_match(/ReleaseBytes\(\(uint8_t\*\) AllocateBytes\(8\)\);/, generated)
    assert_match(/SetLabel\(buffer\);/, generated)
  end

  def test_generate_c_for_foreign_defs_with_external_struct_boundary_reinterpret
    source = <<~MT
      # module demo.main

      import std.shared as shared
      import std.sample as sample

      function main() -> shared.Matrix:
          var matrix = sample.get_matrix()
          sample.set_matrix(shared.IDENTITY)
          sample.set_matrix_ptr(ptr_of(matrix))
          return matrix
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

        external function SetMatrix(matrix: Matrix) -> void
        external function SetMatrixPtr(matrix: ptr[Matrix]) -> void
        external function GetMatrix() -> Matrix
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
        public foreign function set_matrix_ptr(matrix: ptr[shared.Matrix] as ptr[c.Matrix]) -> void = c.SetMatrixPtr
        public foreign function get_matrix() -> shared.Matrix = c.GetMatrix
      MT
    }

    generated = generate_c_from_program_source(source, imported_sources)

    refute_match(/mt_reinterpret_std_c_shared_Matrix_from_std_c_sample_Matrix/, generated)
    refute_match(/mt_reinterpret_std_c_sample_Matrix_from_std_c_shared_Matrix/, generated)
    assert_match(/_Static_assert\(sizeof\([^)]+\) == sizeof\([^)]+\), "FFI layout mismatch: std.c.shared.Matrix vs std.c.sample.Matrix"\)/, generated)
    assert_match(/SetMatrix\(std_shared_IDENTITY\);/, generated)
    assert_match(/SetMatrixPtr\(&matrix\);/, generated)
    assert_match(/Matrix matrix = GetMatrix\(\);/, generated)
    assert_match(/return matrix;/, generated)
  end

  def test_generate_c_for_foreign_defs_with_opaque_handle_projections
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/typedef struct std_window_Window std_window_Window;/, generated)
    assert_match(/std_window_Window\* window = CreateWindow\(\);/, generated)
    assert_match(/DestroyWindow\(window\);/, generated)
  end

  def test_generate_c_for_owned_foreign_release_calls
    source = <<~MT
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
    assert_match(/DestroyWindow\(window\);/, generated)
    assert_match(/window = NULL;/, generated)
    assert_match(/if \(window == NULL\)/, generated)
  end

  def test_generate_c_for_let_else_owned_foreign_release_calls
    source = <<~MT
      # module demo.main

      import std.window as win

      function main() -> int:
          let window = win.create() else:
              return 0
          win.destroy(window)
          if window == null:
              return 1
          return 2
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

  def test_generate_c_for_let_else_status_success_binding
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function main() -> int:
          let value = parse(4) else:
              return 1
          return value + 10
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_result_Result_int_int value = demo_main_parse\(4\);/, generated)
    assert_match(/if \(value\.kind == std_result_Result_int_int_kind_failure\)/, generated)
    assert_match(/return 1;/, generated)
    assert_match(/return value\.data\.success\.value \+ 10;/, generated)
  end

  def test_generate_c_for_let_else_maybe_success_binding
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Option[int]:
          if input < 0:
              return Option[int].none
          return Option[int].some(value= input + 1)

      function main() -> int:
          let value = parse(4) else:
              return 1
          return value + 10
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_option_Option_int value = demo_main_parse\(4\);/, generated)
    assert_match(/if \(value\.kind == std_option_Option_int_kind_none\)/, generated)
    assert_match(/return 1;/, generated)
    assert_match(/return value\.data\.some\.value \+ 10;/, generated)
  end

  def test_generate_c_for_let_else_status_error_binding
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function main() -> int:
          let value = parse(4) else as error:
              return error
          return value + 10
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_result_Result_int_int value = demo_main_parse\(4\);/, generated)
    assert_match(/if \(value\.kind == std_result_Result_int_int_kind_failure\)/, generated)
    assert_match(/return value\.data\.failure\.error;/, generated)
    assert_match(/return value\.data\.success\.value \+ 10;/, generated)
  end

  def test_generate_c_for_var_else_status_success_binding_and_assignment
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function main() -> int:
          var value = parse(4) else:
              return 1
          value += 2
          return value
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_result_Result_int_int value = demo_main_parse\(4\);/, generated)
    assert_match(/if \(value\.kind == std_result_Result_int_int_kind_failure\)/, generated)
    assert_match(/value\.data\.success\.value \+= 2;/, generated)
    assert_match(/return value\.data\.success\.value;/, generated)
  end

  def test_generate_c_for_let_else_status_void_discard_binding
    source = <<~MT
      # module demo.main



      function done() -> void:
          return

      function parse(flag: int) -> Result[void, int]:
          if flag < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function main(flag: int) -> int:
          let _ = parse(flag) else as error:
              return error
          return 0
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/struct std_result_Result_void_int_success \{/, generated)
    assert_match(/uint8_t value;/, generated)
    assert_match(/\.value = \(demo_main_done\(\), 0\)/, generated)
    assert_match(/std_result_Result_void_int __mt_let_else_discard_\d+ = demo_main_parse\(flag\);/, generated)
    assert_match(/if \(__mt_let_else_discard_\d+\.kind == std_result_Result_void_int_kind_failure\)/, generated)
    assert_match(/return __mt_let_else_discard_\d+\.data\.failure\.error;/, generated)
  end

  def test_generate_c_for_result_propagation_expression
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          if input < 0:
              return Result[int, int].failure(error= 7)
          return Result[int, int].success(value= input + 1)

      function render(input: int) -> Result[str, int]:
          let value = parse(input)?
          return Result[str, int].success(value= f"ok \#{value}")
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_result_Result_int_int __mt_propagate_\d+ = demo_main_parse\(input\);/, generated)
    assert_match(/if \(__mt_propagate_\d+\.kind == std_result_Result_int_int_kind_failure\)/, generated)
    assert_match(/return \(std_result_Result_str_int\)\{ \.kind = std_result_Result_str_int_kind_failure, \.data\.failure = \(struct std_result_Result_str_int_failure\)\{ \.error = __mt_propagate_\d+\.data\.failure\.error \} \};/, generated)
    assert_match(/int32_t value = __mt_propagate_\d+\.data\.success\.value;/, generated)
  end

  def test_generate_c_for_result_void_propagation_statement
    source = <<~MT
      # module demo.main



      function done() -> void:
          return

      function parse(flag: int) -> Result[void, int]:
          if flag < 0:
              return Result[void, int].failure(error= 7)
          return Result[void, int].success(value= done())

      function verify(flag: int) -> Result[void, int]:
          parse(flag)?
          return Result[void, int].success(value= done())
    MT

    generated = generate_c_from_program_source(source)

    assert_match(/std_result_Result_void_int __mt_propagate_\d+ = demo_main_parse\(flag\);/, generated)
    assert_match(/if \(__mt_propagate_\d+\.kind == std_result_Result_void_int_kind_failure\)/, generated)
    assert_match(/return __mt_propagate_\d+;/, generated)
    refute_match(/__mt_propagate_\d+\.data\.success\.value/, generated)
  end

  def test_rejects_result_propagation_outside_result_returning_function
    source = <<~MT
      # module demo.main



      function parse(input: int) -> Result[int, int]:
          return Result[int, int].success(value= input + 1)

      function main(input: int) -> int:
          let value = parse(input)?
          return value
    MT

    error = assert_raises(MilkTea::SemaError) do
      generate_c_from_program_source(source)
    end

    assert_match(/propagation requires enclosing function\/proc to return Result/, error.message)
  end

  def test_generate_c_for_typed_opaque_handle_out_projection
    source = <<~MT
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

    generated = generate_c_from_program_source(source, imported_sources)

    assert_match(/typedef struct RawWindow RawWindow;/, generated)
    assert_match(/RawWindow\* window = NULL;/, generated)
    assert_match(/CreateWindow\(&window\)/, generated)
    assert_match(/DestroyWindow\(window\);/, generated)
    assert_match(/window = NULL;/, generated)
  end

  def test_generate_c_for_safe_span_indexing_and_element_assignment
    source = <<~MT

# module demo.span_index_surface

function bump(items: span[int]) -> int:
    let first = items[0]
    items[0] = first + 2
    return items[0]

function main() -> int:
    var value = 7
    let items = span[int](data = ptr_of(value), len = 1)
    return bump(items)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static inline int32_t \*mt_checked_span_index_span_int\(mt_span_int span, uintptr_t index\)/, generated)
    assert_match(/if \(index >= span\.len\) mt_fatal\("span index out of bounds"\);/, generated)
    assert_match(/int32_t first = \(\*mt_checked_span_index_span_int\(items, 0\)\);/, generated)
    assert_match(/\(\*mt_checked_span_index_span_int\(items, 0\)\) = first \+ 2;/, generated)
    assert_match(/return \(\*mt_checked_span_index_span_int\(items, 0\)\);/, generated)
  end

  def test_generate_c_for_mixed_numeric_binary_operations_inserts_explicit_casts
    source = <<~MT

# module demo.numeric_codegen

function main() -> int:
    let sum = 1 + 2.5
    if 3 < 3.5 and sum > 3.0:
        return 1
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/float sum = \(float\) 1 \+ 2\.5f;/, generated)
    assert_match(/if \(\(float\) 3 < 3\.5f && sum > 3\.0f\)/, generated)
  end

  def test_generate_c_for_prefix_cast_syntax
    source = <<~MT

# module demo.prefix_cast_codegen

function main(value: float, a: int, b: int) -> int:
    let left = int<-value
    let right = ubyte<-(a - b)
    return left + int<-right

    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t left = \(int32_t\) value;/, generated)
    assert_match(/uint8_t right = \(uint8_t\) \(a - b\);/, generated)
  end

  def test_generate_c_for_if_expressions
    source = <<~MT

# module demo.if_expr_codegen

function main(ready: bool) -> int:
    let score = if ready: 1 else: 0
    return if ready: score else: score + 1

    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t score = ready \? 1 : 0;/, generated)
    assert_match(/return ready \? score : score \+ 1;/, generated)
  end

  def test_generate_c_for_nested_if_expressions
    source = <<~MT

# module demo.nested_if_expr_codegen

function main(ready: bool, active: bool, fallback: bool, paused: bool, score: int) -> int:
    return if (if ready: active else: fallback): if score > 0: score else: score + 1 else: if paused: 0 else: score + 2

    MT

    generated = generate_c_from_source(source)

    assert_match(/return \(ready \? active : fallback\) \? score > 0 \? score : score \+ 1 : paused \? 0 : score \+ 2;/, generated)
  end

  def test_generate_c_for_variadic_extern_calls
    source = <<~MT

# module demo.variadic_codegen

external function printf(format: cstr, ...) -> int

function main() -> int:
    return printf(c\"value=%d %s\\n\", 7, c\"ok\")

    MT

    generated = generate_c_from_source(source)

    assert_match(/return printf\("value=%d %s\\n", 7, "ok"\);/, generated)
  end

  def test_generate_c_for_lossless_numeric_coercion_at_external_boundaries
    generated = generate_c_from_program_source(
      <<~MT,
        # module demo.external_numeric_codegen

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

    assert_match(/\.r = \(int16_t\) shade/, generated)
    assert_match(/color\.g = \(int16_t\) shade;/, generated)
    assert_match(/set_count\(\(int32_t\) count\);/, generated)
    assert_match(/set_opacity\(\(double\) alpha\);/, generated)
  end

  def test_generate_c_for_exact_compile_time_numeric_coercion
    generated = generate_c_from_program_source(
      <<~MT,
        # module demo.exact_numeric_codegen

        import std.c.demo as demo

        const channel_value: int = 255

        function main() -> int:
            let whole: int = 2.0
            let local_opaque = channel_value
            demo.set_channel(local_opaque)
            demo.set_scale(200)
            return whole
      MT
      {
        "std/c/demo.mt" => <<~MT,
          # module std.c.demo
          external
          external function set_channel(value: ubyte) -> void
          external function set_scale(value: float) -> void
        MT
      },
    )

    assert_match(/int32_t whole = \(int32_t\) 2\.0f;/, generated)
    assert_match(/set_channel\(\(uint8_t\) local_opaque\);/, generated)
    assert_match(/set_scale\(\(float\) 200\);/, generated)
  end

  def test_generate_c_for_contextual_integer_to_float_at_local_assignment_and_return_boundaries
    source = <<~MT

# module demo.contextual_int_to_float_codegen

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

    MT

    generated = generate_c_from_source(source)

    assert_match(/float total = \(float\) value;/, generated)
    assert_match(/total = \(float\) \(value \+ 1\);/, generated)
    assert_match(/total \+= \(float\) \(value \+ 2\);/, generated)
    assert_match(/total -= \(float\) \(value \+ 3\);/, generated)
    assert_match(/point\.x = \(float\) \(value \+ 4\);/, generated)
    assert_match(/return \(float\) \(value \+ 5\);/, generated)
  end

  def test_generate_c_for_contextual_integer_to_float_at_call_and_field_boundaries
    source = <<~MT

# module demo.contextual_float_calls

struct Point:
    x: float
    y: float

function takes_float(value: float) -> float:
    return value

function main() -> int:
    let value = 7
    let point = Point(x = value, y = value * 0.5)
    let direct = takes_float(value)
    let mixed = takes_float(value * 0.5)
    return int<-(point.x + point.y + direct + mixed)

    MT

    generated = generate_c_from_source(source)

    assert_match(/\.x = \(float\) value/, generated)
    assert_match(/\.y = \(float\) value \* 0\.5f/, generated)
    assert_match(/takes_float\(\(float\) value\);/, generated)
    assert_match(/takes_float\(\(float\) value \* 0\.5f\);/, generated)
  end

  def test_generate_c_for_static_interface_requirements_and_specialized_associated_calls
    source = <<~MT

# module demo.static_interface_codegen

interface Tagged:
    static function tag() -> int

struct Counter implements Tagged:
    value: int

extending Counter:
    static function tag() -> int:
        return 33

function tag_of[T implements Tagged]() -> int:
    return T.tag()

function main() -> int:
    return tag_of[Counter]()

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_static_interface_codegen_Counter_tag_static\(void\)/, generated)
    assert_match(/static int32_t demo_static_interface_codegen_tag_of_demo_static_interface_codegen_Counter\(void\)/, generated)
    assert_match(/return demo_static_interface_codegen_Counter_tag_static\(\);/, generated)
  end

  def test_generate_c_for_hash_and_equal_builtins_with_canonical_hooks
    source = <<~MT

# module demo.hash_equal_codegen

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        return uint<-0

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        return true

function same_key[T](left: T, right: T) -> bool:
    return hash[T](left) == hash[T](right) and equal[T](left, right)

function main() -> bool:
    let left = Key(value = 1)
    let right = Key(value = 1)
    return same_key[Key](left, right)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static uint32_t demo_hash_equal_codegen_Key_hash_static\(const demo_hash_equal_codegen_Key\* value\)/, generated)
    assert_match(/static bool demo_hash_equal_codegen_Key_equal_static\(const demo_hash_equal_codegen_Key\* left, const demo_hash_equal_codegen_Key\* right\)/, generated)
    assert_match(/demo_hash_equal_codegen_Key_hash_static\(&left\)/, generated)
    assert_match(/demo_hash_equal_codegen_Key_equal_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_transitive_hash_and_equal_builtins
    source = <<~MT

# module demo.hash_transitive_codegen

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        return uint<-0

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        return true

function inner[U](left: U, right: U) -> bool:
    return hash[U](left) == hash[U](right) and equal[U](left, right)

function outer[T](left: T, right: T) -> bool:
    return inner[T](left, right)

function main() -> bool:
    let left = Key(value = 1)
    let right = Key(value = 1)
    return outer[Key](left, right)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static bool demo_hash_transitive_codegen_inner_demo_hash_transitive_codegen_Key\(demo_hash_transitive_codegen_Key left, demo_hash_transitive_codegen_Key right\)/, generated)
    assert_match(/static bool demo_hash_transitive_codegen_outer_demo_hash_transitive_codegen_Key\(demo_hash_transitive_codegen_Key left, demo_hash_transitive_codegen_Key right\)/, generated)
    assert_match(/return demo_hash_transitive_codegen_inner_demo_hash_transitive_codegen_Key\(left, right\);/, generated)
    assert_match(/demo_hash_transitive_codegen_Key_hash_static\(&left\)/, generated)
    assert_match(/demo_hash_transitive_codegen_Key_equal_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_order_builtin_with_canonical_hook
    source = <<~MT

# module demo.order_codegen

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            let left_value = read(ptr[Key]<-left).value
            let right_value = read(ptr[Key]<-right).value
            if left_value < right_value:
                return -1
            if left_value > right_value:
                return 1
            return 0

function compare[T](left: T, right: T) -> int:
    return order[T](left, right)

function main() -> int:
    let left = Key(value = 1)
    let right = Key(value = 5)
    return compare[Key](left, right)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static int32_t demo_order_codegen_Key_order_static\(const demo_order_codegen_Key\* left, const demo_order_codegen_Key\* right\)/, generated)
    assert_match(/demo_order_codegen_Key_order_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_order_builtin_used_in_binary_comparison
    source = <<~MT

# module demo.order_compare_codegen

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value

function ordered_before_or_equal[T](left: T, right: T) -> bool:
    return order[T](left, right) <= 0

function main() -> bool:
    let left = Key(value = 1)
    let right = Key(value = 2)
    return ordered_before_or_equal[Key](left, right)

    MT

    generated = generate_c_from_source(source)

    assert_match(/static bool demo_order_compare_codegen_ordered_before_or_equal_demo_order_compare_codegen_Key\(demo_order_compare_codegen_Key left, demo_order_compare_codegen_Key right\)/, generated)
    assert_match(/demo_order_compare_codegen_Key_order_static\(&left, &right\)/, generated)
  end

  def test_generate_c_for_builtin_fatal_helper
    source = <<~MT

# module demo.fatal_surface

function main() -> int:
    fatal(\"bad state\")
    return 0

    MT

    generated = generate_c_from_source(source)

    assert_match(/#include <stdio\.h>/, generated)
    assert_match(/#include <stdlib\.h>/, generated)
    refute_match(/static void mt_fatal\(const char\* message\)/, generated)
    assert_match(/static void mt_fatal_str\(mt_str message\)/, generated)
    assert_match(/fwrite\(message\.data, 1, message\.len, stderr\);/, generated)
    assert_match(/abort\(\);/, generated)
    assert_match(/mt_fatal_str\(mt_str_lit_\d+\);/, generated)
  end

  def test_generate_c_for_enum_match_statement_as_switch
    source = <<~MT

# module demo.match_surface

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

    generated = generate_c_from_source(source)

    assert_match(/switch \(kind\) \{/, generated)
    assert_match(/case demo_match_surface_EventKind_quit: \{/, generated)
    assert_match(/case demo_match_surface_EventKind_resize: \{/, generated)
    assert_match(/return 0;/, generated)
    assert_match(/return 1;/, generated)
  end

  def test_generate_c_for_range_and_array_for_loops
    source = <<~MT

# module demo.for_surface

function sum(items: array[int, 4]) -> int:
    var total = 0
    for item in items:
        total += item
    for i in 0..4:
        total += i
    return total

function main() -> int:
    return sum(array[int, 4](1, 2, 3, 4))

    MT

    generated = generate_c_from_source(source)

    assert_match(/for \(uintptr_t __mt_for_index_\d+ = 0; __mt_for_index_\d+ < 4; __mt_for_index_\d+ \+= 1\)/, generated)
    assert_match(/int32_t item = __mt_for_items_\d+\[__mt_for_index_\d+\];/, generated)
    assert_match(/for \(int32_t i = 0; i < 4; i \+= 1\)/, generated)
    refute_match(/int32_t i = __mt_for_index_\d+;/, generated)
    refute_match(/int32_t __mt_for_stop_\d+ = 4;/, generated)
  end

  def test_generate_c_for_dot_dot_range_syntax
    source = <<~MT

# module demo.dot_dot_range

function sum(n: int) -> int:
    var total = 0
    for i in 0..n:
        total += i
    return total

function main() -> int:
    return sum(4)

    MT

    generated = generate_c_from_source(source)

    # start..end with non-constant bound should hoist stop once
    assert_match(/int32_t __mt_for_stop_\d+ = n;/, generated)
    assert_match(/for \(int32_t i = 0; i < __mt_for_stop_\d+; i \+= 1\)/, generated)
  end

  def test_generate_c_for_dot_dot_range_with_constant_end
    source = <<~MT

# module demo.dot_dot_range_const

function sum_to_ten() -> int:
    var total = 0
    for i in 0..10:
        total += i
    return total

    MT

    generated = generate_c_from_source(source)

    # constant stop should be inlined, not hoisted
    assert_match(/for \(int32_t i = 0; i < 10; i \+= 1\)/, generated)
    refute_match(/int32_t __mt_for_stop_\d+ = 10;/, generated)
  end

  def test_generate_c_range_index_assignment
    source = <<~MT

# module demo.range_index_assign

function fill3(buf: ptr[float]) -> void:
    unsafe:
        buf[0..3] = (1.0, 2.0, 3.0)

    MT

    generated = generate_c_from_source(source)

    assert_match(/buf\[0\] = 1\.0/, generated)
    assert_match(/buf\[1\] = 2\.0/, generated)
    assert_match(/buf\[2\] = 3\.0/, generated)
  end

  def test_generate_c_preserves_hoisted_stop_for_non_constant_range_bound
    source = <<~MT

# module demo.for_stop_surface

function main() -> int:
    var stop = 4
    var total = 0
    for i in 0..stop:
        stop += 1
        total += i
    return total + stop

    MT

    generated = generate_c_from_source(source)

    assert_match(/int32_t __mt_for_stop_\d+ = stop;/, generated)
    assert_match(/for \(int32_t i = 0; i < __mt_for_stop_\d+; i \+= 1\)/, generated)
  end

  def test_generate_c_for_break_and_continue_inside_match_with_for_loop
    source = <<~MT

# module demo.loop_control_surface

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

    generated = generate_c_from_source(source)

    assert_match(/for \(uintptr_t __mt_for_index_\d+ = 0; __mt_for_index_\d+ < 4; __mt_for_index_\d+ \+= 1\)/, generated)
    assert_match(/goto __mt_loop_break_\d+;/, generated)
    assert_match(/continue;/, generated)
    refute_match(/goto __mt_loop_continue_\d+;/, generated)
    refute_match(/__mt_loop_continue_\d+:;/, generated)
    assert_match(/__mt_loop_break_\d+:;/, generated)
  end

  # ── Inline compile-time statements ────────────────────────────────────────

  def test_generate_c_for_inline_if_const_true
    source = <<~MT
      const DEBUG: bool = true

      function main() -> int:
          inline if DEBUG:
              return 1
          else:
              return 2
    MT

    generated = generate_c_from_source(source)
    assert_match(/return 1;/, generated)
    refute_match(/return 2;/, generated)
  end

  def test_generate_c_for_inline_if_const_false
    source = <<~MT
      const DEBUG: bool = false

      function main() -> int:
          inline if DEBUG:
              return 1
          else:
              return 2
    MT

    generated = generate_c_from_source(source)
    refute_match(/return 1;/, generated)
    assert_match(/return 2;/, generated)
  end

  def test_generate_c_for_when_stmt
    source = <<~MT
      const TARGET: Kind = Kind.a

      enum Kind: ubyte
          a = 0
          b = 1

      function label() -> str:
          when TARGET:
              Kind.a:
                  return "a"
              Kind.b:
                  return "b"
    MT

    generated = generate_c_from_source(source)
    assert_match(/"a"/, generated)
    refute_match(/"b"/, generated)
  end

  def test_generate_c_for_module_level_when_stmt
    source = <<~MT
      const TARGET: Kind = Kind.a

      enum Kind: ubyte
          a = 0
          b = 1

      when TARGET:
          Kind.a:
              function get_value() -> int:
                  return 1
              const LABEL: str = "a"
          Kind.b:
              function get_value() -> int:
                  return 2
              const LABEL: str = "b"

      function main() -> int:
          return get_value()
    MT

    generated = generate_c_from_source(source)
    assert_match(/"a"/, generated)
    refute_match(/"b"/, generated)
    assert_match(/get_value/, generated)
  end

  # ── Const function ────────────────────────────────────────────────────────

  def test_generate_c_for_const_function_folded
    source = <<~MT
      const function square(x: int) -> int:
          return x * x

      const RESULT: int = square(5)

      function main() -> int:
          return RESULT
    MT

    generated = generate_c_from_source(source)
    assert_match(/25/, generated)
  end

  def test_generate_c_for_const_function_runtime
    source = <<~MT
      const function add_one(x: int) -> int:
          return x + 1

      function main() -> int:
          return add_one(41)
    MT

    generated = generate_c_from_source(source)
    assert_match(/add_one/, generated)
  end

  # ── Native math types ─────────────────────────────────────────────────────

  def test_generate_c_for_vec3_construction
    source = <<~MT
      function direction() -> vec3:
          return vec3(x = 1.0, y = 0.0, z = 0.0)
    MT

    generated = generate_c_from_source(source)
    assert_match(/vec3/, generated)
  end

  def test_generate_c_for_vec3_add
    source = <<~MT
      function add(a: vec3, b: vec3) -> vec3:
          return a + b
    MT

    generated = generate_c_from_source(source)
    assert_match(/vec3/, generated)
  end

  def test_generate_c_for_mat4_identity
    source = <<~MT
      function identity() -> mat4:
          return mat4(
              col0 = vec4(x = 1.0, y = 0.0, z = 0.0, w = 0.0),
              col1 = vec4(x = 0.0, y = 1.0, z = 0.0, w = 0.0),
              col2 = vec4(x = 0.0, y = 0.0, z = 1.0, w = 0.0),
              col3 = vec4(x = 0.0, y = 0.0, z = 0.0, w = 1.0),
          )
    MT

    generated = generate_c_from_source(source)
    assert_match(/mat4/, generated)
  end

  def test_generate_c_for_quat_identity
    source = <<~MT
      function identity() -> quat:
          return quat(x = 0.0, y = 0.0, z = 0.0, w = 1.0)
    MT

    generated = generate_c_from_source(source)
    assert_match(/quat/, generated)
  end

  # ── SoA ───────────────────────────────────────────────────────────────────

  def test_generate_c_for_soa_type_declaration
    source = <<~MT
      struct Particle:
          x: float
          y: float

      function sum_x(data: SoA[Particle, 16]) -> float:
          return data[0].x
    MT

    generated = generate_c_from_source(source)
    assert_match(/mt_soa_/, generated)
  end

  def test_generate_c_for_struct_with_partial_update
    source = <<~MT
      struct Point:
          x: float
          y: float
          z: float

      function move(p: Point) -> Point:
          return p.with(x = 10.0, z = 20.0)
    MT

    generated = generate_c_from_source(source)
    assert_match(/\.x = 10\.0f/, generated)
    assert_match(/\.y = p\.y/, generated)
    assert_match(/\.z = 20\.0f/, generated)
  end

  def test_generate_c_for_struct_with_lifetime_ref_field
    source = <<~MT
      struct Cursor[@a]:
          data: ref[@a, span[ubyte]]
          position: ptr_uint

      function advance(c: ref[Cursor]) -> void:
          pass
    MT

    generated = generate_c_from_source(source)
    assert_match(/mt_span_ubyte \*data/, generated)
  end

  def test_generate_c_for_nested_struct
    source = <<~MT
      struct Rectangle:
          x: float
          y: float

          struct Edge:
              start: float
              end: float

          top_edge: Edge
          left_edge: Edge
    MT

    generated = generate_c_from_source(source)
    assert_match(/typedef struct \w+_Rectangle_Edge \w+_Rectangle_Edge;/, generated)
    assert_match(/struct \w+_Rectangle_Edge \{/, generated)
    assert_match(/\w+_Rectangle_Edge top_edge;/, generated)
  end

  def test_generate_c_for_deeply_nested_struct
    source = <<~MT
      struct A:
          struct B:
              struct C:
                  value: int
              x: C
          y: B
    MT

    generated = generate_c_from_source(source)
    assert_match(/typedef struct \w+_A_B_C/, generated)
    assert_match(/typedef struct \w+_A_B\b/, generated)
    assert_match(/struct \w+_A_B_C \{/, generated)
    assert_match(/\w+_A_B_C x;/, generated)
    assert_match(/\w+_A_B y;/, generated)
  end

end
