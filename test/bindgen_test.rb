# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaBindgenTest < Minitest::Test
  def test_generate_emits_parseable_extern_module_for_sample_header
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      File.write(header_path, <<~C)
        #include <stdarg.h>
        #include <stddef.h>
        #include <stdint.h>

        typedef struct Vec2 {
          float x;
          float y;
        } Vec2;

        typedef struct Counters {
          int32_t value;
          size_t capacity;
        } Counters;

        #define HOME ((Vec2){ 1.0f, 2.0f })
        #define PIXEL_RATIO 2
        #define GREETING "Milk"
        #define DYNAMIC_SIZE runtime_size()
        #if 0
        #define INACTIVE_LIMIT missing_symbol
        #endif

        typedef struct Material {
          float params[4];
          char name[32];
        } Material;

        typedef void (*LogCallback)(int, const char *);
        typedef void (*TraceCallback)(int, va_list);
        typedef _Complex double ComplexValue;

        static const int MAGIC = 7;
        static const unsigned long WINDOW_FLAG = 32UL;
        static const float SCALE = 2.5f;
        static const Vec2 ORIGIN = { 0.0f, 0.0f };
        static const char *TITLE = "Milk";

        typedef enum Mode {
          MODE_A = 1,
          MODE_B = 3
        } Mode;

        typedef enum WindowFlags {
          WINDOW_VISIBLE = 1,
          WINDOW_RESIZABLE = 2
        } WindowFlags;

        typedef enum TraceLevel {
          TRACE_ALL = 0,
          TRACE_LOG,
          TRACE_DEBUG
        } TraceLevel;

        struct Hidden;

        typedef unsigned int Flags;
        typedef unsigned int HiddenU32;
        typedef HiddenU32 PublicU32;

        int add(int a, int b);
        int add(int a, int b);
        size_t fill_buffer(uint32_t value, size_t count);
        wchar_t widen(wchar_t value);
        int runtime_size(void);
        long double measure_long_double(void);
        const char *name_of(Mode mode);
        int logf(const char *format, ...);
        void set_callback(LogCallback callback);
        void set_trace_callback(void (*callback)(int, const char *, va_list));
        void take_hidden(struct Hidden *hidden);
        void inspect_pointer(const void *data);
        void read_vec(const Vec2 *vec);

        int consume_strings(char **restrict values, char *const *restrict tokens);
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        link_libraries: ["sample"],
        include_directives: ["sample.h"],
        clang:,
      )

      assert_match(/extern module std\.c\.sample:/, generated)
      assert_match(/link "sample"/, generated)
      assert_match(/include "sample\.h"/, generated)
      assert_match(/struct Vec2:/, generated)
      assert_match(/struct Counters:/, generated)
      assert_match(/struct Material:/, generated)
      assert_match(/value: i32/, generated)
      assert_match(/capacity: usize/, generated)
      assert_match(/params: array\[f32, 4\]/, generated)
      assert_match(/name: array\[char, 32\]/, generated)
      assert_match(/type LogCallback = fn\(arg0: i32, arg1: cstr\) -> void/, generated)
      assert_match(/opaque va_list = c"va_list"/, generated)
      assert_match(/type TraceCallback = fn\(arg0: i32, arg1: va_list\) -> void/, generated)
      assert_match(/const HOME: Vec2 = Vec2\(x = 1.0, y = 2.0\)/, generated)
      assert_match(/const PIXEL_RATIO: i32 = 2/, generated)
      refute_match(/const GREETING:/, generated)
      refute_match(/const DYNAMIC_SIZE:/, generated)
      refute_match(/const INACTIVE_LIMIT:/, generated)
      assert_match(/const MAGIC: i32 = 7/, generated)
      assert_match(/const WINDOW_FLAG: usize = 32/, generated)
      assert_match(/const SCALE: f32 = 2.5/, generated)
      assert_match(/const ORIGIN: Vec2 = Vec2\(x = 0.0, y = 0.0\)/, generated)
      assert_match(/const TITLE: cstr = c"Milk"/, generated)
      assert_match(/enum Mode: i32/, generated)
      assert_match(/flags WindowFlags: i32/, generated)
      assert_match(/flags TraceLevel: i32/, generated)
      assert_match(/TRACE_ALL = 0/, generated)
      assert_match(/TRACE_LOG = 1/, generated)
      assert_match(/TRACE_DEBUG = 2/, generated)
      assert_match(/opaque Hidden = c"struct Hidden"/, generated)
      assert_match(/type Flags = u32/, generated)
      assert_match(/type HiddenU32 = u32/, generated)
      assert_match(/type PublicU32 = u32/, generated)
      refute_match(/type ComplexValue =/, generated)
      refute_match(/extern def measure_long_double/, generated)
      assert_match(/extern def add\(a: i32, b: i32\) -> i32/, generated)
      assert_equal 1, generated.scan("extern def add(a: i32, b: i32) -> i32").length
      assert_match(/extern def fill_buffer\(value: u32, count: usize\) -> usize/, generated)
      assert_match(/extern def widen\(value: i32\) -> i32/, generated)
      assert_match(/extern def name_of\(mode: Mode\) -> cstr/, generated)
      assert_match(/extern def logf\(format: cstr, \.\.\.\) -> i32/, generated)
      assert_match(/extern def set_callback\(callback: fn\(arg0: i32, arg1: cstr\) -> void\) -> void/, generated)
      assert_match(/extern def set_trace_callback\(callback: fn\(arg0: i32, arg1: cstr, arg2: va_list\) -> void\) -> void/, generated)
      assert_match(/extern def take_hidden\(hidden: ptr\[Hidden\]\) -> void/, generated)
      assert_match(/extern def inspect_pointer\(data: const_ptr\[void\]\) -> void/, generated)
      assert_match(/extern def read_vec\(vec: const_ptr\[Vec2\]\) -> void/, generated)
      assert_match(/extern def consume_strings\(values: ptr\[ptr\[char\]\], tokens: const_ptr\[ptr\[char\]\]\) -> i32/, generated)

      File.write(output_path, generated)
      analysis = MilkTea::ModuleLoader.check_file(output_path)

      assert_equal :extern_module, analysis.module_kind
      assert_equal "std.c.sample", analysis.module_name
      assert_includes analysis.values.keys, "MAGIC"
      assert_includes analysis.values.keys, "HOME"
      assert_includes analysis.values.keys, "PIXEL_RATIO"
      assert_includes analysis.values.keys, "ORIGIN"
      assert_includes analysis.types.keys, "LogCallback"
      assert_includes analysis.functions.keys, "add"
      assert_includes analysis.functions.keys, "set_callback"
      assert_includes analysis.functions.keys, "consume_strings"
      assert_includes analysis.types.keys, "Vec2"
      assert_includes analysis.types.keys, "Counters"
      assert_includes analysis.types.keys, "Material"
      assert_includes analysis.types.keys, "Hidden"
    end
  end

  def test_generate_applies_function_param_type_overrides
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-overrides") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, <<~C)
        int load_font_ex(int *codepoints, int codepointCount);
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
        function_param_type_overrides: {
          "load_font_ex" => { "codepoints" => "ptr[i32]?" },
        },
      )

      assert_match(/extern def load_font_ex\(codepoints: ptr\[i32\]\?, codepointCount: i32\) -> i32/, generated)
    end
  end

  def test_generate_handles_implicit_zero_initialized_aggregate_constants
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-zero-init") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      File.write(header_path, <<~C)
        #include <stdint.h>

        typedef struct Cache {
          uint16_t count;
          uint8_t indexA[3];
          uint8_t indexB[3];
        } Cache;

        static const Cache EMPTY = {0};
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
      )

      assert_match(/const EMPTY: Cache = Cache\(count = 0, indexA = array\[u8, 3\]\(0, 0, 0\), indexB = array\[u8, 3\]\(0, 0, 0\)\)/, generated)

      File.write(output_path, generated)
      analysis = MilkTea::ModuleLoader.check_file(output_path)

      assert_equal :extern_module, analysis.module_kind
      assert_equal "std.c.sample", analysis.module_name
      assert_includes analysis.values.keys, "EMPTY"
    end
  end

  def test_generate_synthesizes_opaque_record_for_leaked_pointer_tag
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-opaque-record") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      File.write(header_path, <<~C)
        typedef struct Holder {
          struct HiddenNode *node;
        } Holder;
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
      )

      assert_match(/opaque HiddenNode = c"struct HiddenNode"/, generated)
      assert_match(/struct Holder:\n\s+node: ptr\[HiddenNode\]/, generated)

      File.write(output_path, generated)
      analysis = MilkTea::ModuleLoader.check_file(output_path)

      assert_equal :extern_module, analysis.module_kind
      assert_equal "std.c.sample", analysis.module_name
      assert_includes analysis.types.keys, "HiddenNode"
      assert_includes analysis.types.keys, "Holder"
    end
  end

  def test_generate_supports_function_type_typedefs
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-function-typedef") do |dir|
      header_path = File.join(dir, "sample.h")
      output_path = File.join(dir, "sample.mt")
      File.write(header_path, <<~C)
        typedef float FrictionCallback(float a, unsigned long long material_a, float b, unsigned long long material_b);

        typedef struct WorldDef {
          FrictionCallback *friction_callback;
        } WorldDef;
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
      )

      assert_match(/type FrictionCallback = fn\(arg0: f32, arg1: u64, arg2: f32, arg3: u64\) -> f32/, generated)
      assert_match(/struct WorldDef:\n\s+friction_callback: ptr\[FrictionCallback\]/, generated)

      File.write(output_path, generated)
      analysis = MilkTea::ModuleLoader.check_file(output_path)

      assert_equal :extern_module, analysis.module_kind
      assert_equal "std.c.sample", analysis.module_name
      assert_includes analysis.types.keys, "FrictionCallback"
      assert_includes analysis.types.keys, "WorldDef"
    end
  end

  def test_generate_applies_function_return_type_overrides
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-return-overrides") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, <<~C)
        void *allocate(int count);
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
        function_return_type_overrides: {
          "allocate" => "ptr[void]?",
        },
      )

      assert_match(/extern def allocate\(count: i32\) -> ptr\[void\]\?/, generated)
    end
  end

  def test_generate_applies_field_type_overrides
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-field-overrides") do |dir|
      header_path = File.join(dir, "sample.h")
      File.write(header_path, <<~C)
        typedef struct Mesh {
          unsigned short *indices;
          float *vertices;
        } Mesh;
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h"],
        clang:,
        field_type_overrides: {
          "Mesh" => { "indices" => "ptr[u16]?" },
        },
      )

      assert_match(/indices: ptr\[u16\]\?/, generated)
      assert_match(/vertices: ptr\[f32\]/, generated)
    end
  end

  def test_generate_applies_module_imports_and_type_overrides
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-type-overrides") do |dir|
      dep_path = File.join(dir, "dep.h")
      header_path = File.join(dir, "sample.h")
      File.write(dep_path, <<~C)
        typedef struct Vec3 { float x; float y; float z; } Vec3;
      C
      File.write(header_path, <<~C)
        typedef struct Light { Vec3 position; } Light;
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["dep.h", "sample.h"],
        module_imports: [{ module_name: "std.c.dep", alias: "dep" }],
        clang:,
        clang_args: ["-I#{dir}", "-include", "dep.h"],
        type_overrides: { "Vec3" => "dep.Vec3" },
      )

      assert_match(/^    import std\.c\.dep as dep$/, generated)
      assert_match(/^    include "dep\.h"$/, generated)
      assert_match(/^    include "sample\.h"$/, generated)
      assert_match(/^        position: dep\.Vec3$/, generated)
    end
  end

  def test_generate_captures_macro_constants_from_nested_tracked_headers
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-tracked-macros") do |dir|
      inner_path = File.join(dir, "inner.h")
      outer_path = File.join(dir, "outer.h")
      wrapper_path = File.join(dir, "wrapper.h")

      File.write(inner_path, <<~C)
        #define SAMPLE_INIT_VIDEO 0x00000020u
        #define SAMPLE_OLD_ALIAS renamed_SAMPLE_INIT_VIDEO
        #define SAMPLE_EPSILON 1.25E-4f
      C
      File.write(outer_path, <<~C)
        #include "inner.h"
        typedef unsigned int SampleFlags;
      C
      File.write(wrapper_path, <<~C)
        #include "outer.h"
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path: wrapper_path,
        tracked_header_prefixes: [dir],
        declaration_name_prefixes: ["SAMPLE_", "Sample"],
        include_directives: ["wrapper.h"],
        clang: clang,
        clang_args: ["-I#{dir}"],
      )

      assert_match(/type SampleFlags = u32/, generated)
      assert_match(/const SAMPLE_INIT_VIDEO: u32 = 32/, generated)
      assert_match(/const SAMPLE_EPSILON: f32 = 1\.25\d*E-4/, generated)
      refute_match(/const SAMPLE_OLD_ALIAS:/, generated)
    end
  end

  def test_generate_supports_bindgen_defines_and_extra_include_directives
    clang = ENV.fetch("CLANG", "clang")
    skip "clang not available: #{clang}" unless executable_available?(clang)

    Dir.mktmpdir("milk-tea-bindgen-extra-includes") do |dir|
      header_path = File.join(dir, "sample.h")
      main_header_path = File.join(dir, "sample_main.h")

      File.write(header_path, <<~C)
        typedef unsigned int SampleFlags;
      C
      File.write(main_header_path, <<~C)
        #ifdef SAMPLE_MAIN_HANDLED
        typedef int (*SampleMain)(int argc, char **argv);
        int SampleRun(int argc, char **argv, SampleMain main_fn);
        #endif
      C

      generated = MilkTea::Bindgen.generate(
        module_name: "std.c.sample",
        header_path:,
        include_directives: ["sample.h", "sample_main.h"],
        bindgen_defines: ["SAMPLE_MAIN_HANDLED=1"],
        bindgen_include_directives: ["sample_main.h"],
        clang:,
        clang_args: ["-I#{dir}"],
      )

      assert_match(/type SampleFlags = u32/, generated)
      assert_match(/extern def SampleRun\(argc: i32, argv: ptr\[ptr\[char\]\], main_fn: fn\(arg0: i32, arg1: ptr\[ptr\[char\]\]\) -> i32\) -> i32/, generated)
    end
  end

  private

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
