# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPrettyPrinterTest < Minitest::Test
  def test_formats_ast_like_source
    source = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(ref_of(counter))",
      "    unsafe:",
      "        counter_ptr.value = 7",
      "    return counter.value",
      "",
    ].join("\n")

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_module_ast_like_source
    source = <<~MT
      extern module std.c.sample:
          link "sample"
          include "sample.h"

          extern def add(a: i32, b: i32) -> i32
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_module_imports_like_source
    source = <<~MT
      extern module std.c.helper:
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

      pub struct Counter:
          value: i32

      methods Counter:
          pub def read() -> i32:
              return this.value

          def bump() -> void:
              this.value += 1

      pub def main() -> i32:
          let counter = Counter(value = 3)
          return counter.read()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_variadic_extern_module_ast_like_source
    source = <<~MT
      extern module std.c.stdio:
          include "stdio.h"

          extern def printf(format: cstr, ...) -> i32
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_extern_opaque_with_explicit_c_name_like_source
    source = <<~MT
      extern module std.c.time:
          opaque tm = c"struct tm"
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_foreign_declarations_and_calls_like_source
    source = <<~MT
      module std.raylib

      import std.c.raylib as c

      pub foreign def load_file_data(file_name: str as cstr, out data_size: i32) -> ptr[u8]? = c.LoadFileData

      pub foreign def set_shader_value[T](shader: Shader, loc_index: i32, in value: T as const_ptr[void], uniform_type: i32) -> void = c.SetShaderValue

      pub foreign def close_window(consuming window: Window) -> void = c.CloseWindow

      pub foreign def save_file_data(file_name: str as cstr, data: span[u8]) -> bool = c.SaveFileData(file_name, data.data, i32<-data.len)

      def main(path: str) -> ptr[u8]?:
          var data_size = 0
          let contrast = 1.0
          set_shader_value(Shader(), 0, in contrast, 0)
          return load_file_data(path, out data_size)
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_array_char_zero_construction_like_source
    source = <<~MT
      module demo.array_char

      def main() -> i32:
          var buffer = zero[array[char, 64]]()
          buffer[0] = 65
          return 0
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_typed_local_without_initializer_like_source
    source = <<~MT
      module demo.locals

      def main() -> void:
          var buffer: array[char, 64]
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_defer_block_like_source
    source = <<~MT
      module demo.cleanup

      def main() -> void:
          defer:
              first_cleanup()
              second_cleanup()
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_lowered_ir_as_structured_output
    source = [
      "module demo.pretty",
      "",
      "struct Counter:",
      "    value: i32",
      "",
      "def main() -> i32:",
      "    var counter = Counter(value = 3)",
      "    let counter_ptr = ptr_of(ref_of(counter))",
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
    assert_includes output, "fn main() -> i32 [entry]:"
    assert_includes output, "let counter_ptr: ptr[demo.pretty.Counter] = ptr[demo.pretty.Counter]<-&counter"
    assert_includes output, "counter_ptr->value = 7"
    assert_includes output, "return counter.value"
  end

  def test_formats_lowered_ir_for_clauses
    source = [
      "module demo.pretty_for",
      "",
      "def keep(value: i32) -> void:",
      "    return",
      "",
      "def main() -> void:",
      "    for i in 0..3:",
      "        keep(i)",
      "",
    ].join("\n")

    output = with_program(source) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "fn main() -> void [entry]:"
    assert_includes output, "for i: i32 = 0; i < 3; i += 1:"
    assert_includes output, "demo_pretty_for_keep(i)"
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
