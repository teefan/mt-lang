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
        void set_callback(LogCallback callback);
        void take_hidden(struct Hidden *hidden);

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
      assert_match(/capacity: u64/, generated)
      assert_match(/params: array\[f32, 4\]/, generated)
      assert_match(/name: array\[char, 32\]/, generated)
      assert_match(/type LogCallback = fn\(arg0: i32, arg1: cstr\) -> void/, generated)
      assert_match(/opaque __va_list_tag/, generated)
      assert_match(/type va_list = array\[__va_list_tag, 1\]/, generated)
      assert_match(/type TraceCallback = fn\(arg0: i32, arg1: va_list\) -> void/, generated)
      assert_match(/const HOME: Vec2 = Vec2\(x = 1.0, y = 2.0\)/, generated)
      assert_match(/const PIXEL_RATIO: i32 = 2/, generated)
      refute_match(/const GREETING:/, generated)
      refute_match(/const DYNAMIC_SIZE:/, generated)
      refute_match(/const INACTIVE_LIMIT:/, generated)
      assert_match(/const MAGIC: i32 = 7/, generated)
      assert_match(/const SCALE: f32 = 2.5/, generated)
      assert_match(/const ORIGIN: Vec2 = Vec2\(x = 0.0, y = 0.0\)/, generated)
      assert_match(/const TITLE: cstr = c"Milk"/, generated)
      assert_match(/enum Mode: i32/, generated)
      assert_match(/flags WindowFlags: i32/, generated)
      assert_match(/flags TraceLevel: i32/, generated)
      assert_match(/TRACE_ALL = 0/, generated)
      assert_match(/TRACE_LOG = 1/, generated)
      assert_match(/TRACE_DEBUG = 2/, generated)
      assert_match(/opaque Hidden/, generated)
      assert_match(/type Flags = u32/, generated)
      assert_match(/type HiddenU32 = u32/, generated)
      assert_match(/type PublicU32 = u32/, generated)
      refute_match(/type ComplexValue =/, generated)
      refute_match(/extern def measure_long_double/, generated)
      assert_match(/extern def add\(a: i32, b: i32\) -> i32/, generated)
      assert_equal 1, generated.scan("extern def add(a: i32, b: i32) -> i32").length
      assert_match(/extern def fill_buffer\(value: u32, count: u64\) -> usize/, generated)
      assert_match(/extern def widen\(value: i32\) -> i32/, generated)
      assert_match(/extern def name_of\(mode: Mode\) -> cstr/, generated)
      assert_match(/extern def set_callback\(callback: fn\(arg0: i32, arg1: cstr\) -> void\) -> void/, generated)
      assert_match(/extern def take_hidden\(hidden: ptr\[Hidden\]\) -> void/, generated)
      assert_match(/extern def consume_strings\(values: ptr\[ptr\[char\]\], tokens: ptr\[ptr\[char\]\]\) -> i32/, generated)

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

  private

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
