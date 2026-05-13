# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPrettyPrinterTest < Minitest::Test
  def test_formats_ast_like_source
    source = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: int",
      "",
      "function main() -> int:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(counter)",
      "    unsafe: counter_ptr.value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_single_statement_unsafe_block_canonically
    source = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: int",
      "",
      "function main() -> int:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(counter)",
      "    unsafe:",
      "        counter_ptr.value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    expected = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: int",
      "",
      "function main() -> int:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(counter)",
      "    unsafe: counter_ptr.value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    ast = MilkTea::Parser.parse(source)

    assert_equal expected, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_multi_statement_unsafe_block_like_source
    source = [
      "module demo.pretty",
      "",
      "function main(ptr: ptr[int]) -> int:",
      "    unsafe:",
      "        let value = read(ptr)",
      "        return value",
      "",
    ].join("\n")

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_let_else_with_error_binding_like_source
    source = <<~MT
      module demo.pretty

      function main(result: int) -> int:
          let value = result else as error:
              return error
          return value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_module_ast_like_source
    source = <<~MT
      external module std.c.sample:
          link "sample"
          include "sample.h"

          external function add(a: int, b: int) -> int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_module_imports_like_source
    source = <<~MT
      external module std.c.helper:
          import std.c.dep as dep

          include "helper.h"

          struct Holder:
              value: dep.Vec
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_public_declarations_and_methods_like_source
    source = <<~MT
      module demo.pretty

      public struct Counter:
          value: int

      methods Counter:
          public function read() -> int:
              return this.value

          function bump() -> void:
              this.value += 1

      public function main() -> int:
          let counter = Counter(value = 3)
          return counter.read()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_generic_methods_block_targets_like_source
    source = <<~MT
      module demo.pretty_generic_methods

      struct Box[T]:
          value: T

      methods Box[T]:
          function get() -> T:
              return this.value
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_variadic_extern_module_ast_like_source
    source = <<~MT
      external module std.c.stdio:
          include "stdio.h"

          external function printf(format: cstr, ...) -> int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_opaque_with_explicit_c_name_like_source
    source = <<~MT
      external module std.c.time:
          opaque tm = c"struct tm"
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_struct_with_explicit_c_name_like_source
    source = <<~MT
      external module std.c.time:
          struct timespec = c"struct timespec":
              tv_sec: ptr_int
              tv_nsec: ptr_int
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_module_groups_simple_declarations_by_kind
    source = <<~MT
      external module std.c.sample:
          include "sample.h"

          opaque Handle = c"struct Handle"
          type Flags = uint

          const MAGIC: int = 7
          const LIMIT: int = 8

          external function init() -> int
          external function close() -> void
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_foreign_declarations_and_calls_like_source
    source = <<~MT
      module std.raylib

      import std.c.raylib as c

      public foreign function load_file_data(file_name: str as cstr, out data_size: int) -> ptr[ubyte]? = c.LoadFileData

      public foreign function set_shader_value[T](shader: Shader, loc_index: int, in value: T as const_ptr[void], uniform_type: int) -> void = c.SetShaderValue

      public foreign function close_window(consuming window: Window) -> void = c.CloseWindow

      public foreign function save_file_data(file_name: str as cstr, data: span[ubyte]) -> bool = c.SaveFileData(file_name, data.data, int<-data.len)

      function main(path: str) -> ptr[ubyte]?:
          var data_size = 0
          let contrast = 1.0
          set_shader_value(Shader(), 0, contrast, 0)
          return load_file_data(path, data_size)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_variadic_foreign_declarations_like_source
    source = <<~MT
      module std.stdio

      import std.c.stdio as c

      public foreign function print(format: str as cstr, ...) -> int = c.printf
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_array_char_zero_construction_like_source
    source = <<~MT
      module demo.array_char

      function main() -> int:
          var buffer = zero[array[char, 64]]
          buffer[0] = 65
          return 0
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_typed_local_without_initializer_like_source
    source = <<~MT
      module demo.locals

      function main() -> void:
          var buffer: array[char, 64]
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_defer_block_like_source
    source = <<~MT
      module demo.cleanup

      function main() -> void:
          defer:
              first_cleanup()
              second_cleanup()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_heredoc_literals_like_source
    source = <<~MT
      module demo.heredoc

      const shader: cstr = c<<-GLSL
          #version 330
          void main()
          {
          }
      GLSL
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_multiline_adjacent_string_literals_like_source
    source = <<~MT
      module demo.adjacent

      const title: str = "Milk Tea keeps this text readable"
          " while storing a single logical line."
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_lowered_ir_as_structured_output
    source = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: int",
      "",
      "function main() -> int:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(counter)",
      "    unsafe:",
      "        counter_ptr.value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    output = with_program(source) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "program demo.pretty"
    assert_includes output, "struct Counter as demo_pretty_Counter:"
    assert_includes output, "fn main() -> int [entry]:"
    assert_includes output, "let counter_ptr: ptr[demo.pretty.Counter] = &counter"
    assert_includes output, "counter_ptr->value = 7"
    assert_includes output, "return counter.value"
  end

  def test_formats_lowered_ir_for_clauses
    source = [
      "module demo.pretty_for",
      "",
      "function keep(value: int) -> void:",
      "    return",
      "",
      "function main() -> void:",
      "    for i in 0..3:",
      "        keep(i)",
      "",
    ].join("\n")

    output = with_program(source) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "fn main as demo_pretty_for_main() -> void:"
    assert_includes output, "fn main() -> int [entry]:"
    assert_includes output, "for i: int = 0; i < 3; i += 1:"
    assert_includes output, "demo_pretty_for_keep(i)"
  end

  def test_formats_lowered_ir_with_nil_else_and_switch_default_case
    source = [
      "module demo.pretty_match",
      "",
      "function describe(code: int) -> int:",
      "    if code < 0:",
      "        return 0",
      "",
      "    match code:",
      "        1:",
      "            return 10",
      "        _:",
      "            return 20",
      "",
      "function main() -> int:",
      "    return describe(2)",
      "",
    ].join("\n")

    output = with_program(source) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "fn describe as demo_pretty_match_describe(code: int) -> int:"
    assert_includes output, "if code < 0:"
    assert_includes output, "switch code:"
    assert_includes output, "default:"
  end

  private

  def with_program(source)
    Dir.mktmpdir("milk-tea-pretty-printer") do |dir|
      path = File.join(dir, "program.mt")
      File.write(path, source)
      yield MilkTea::ModuleLoader.check_program(path)
    end
  end
end
