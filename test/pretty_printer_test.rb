# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaPrettyPrinterTest < Minitest::Test
  def test_formats_ast_like_source
    source = <<~MT
      module demo.pretty

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = raw(addr(counter))
          unsafe:
              value(counter_ptr).value = 7
          return counter.value
    MT

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

  def test_formats_variadic_extern_module_ast_like_source
    source = <<~MT
      extern module std.c.stdio:
          include "stdio.h"

          extern def printf(format: cstr, ...) -> i32
    MT

    ast = MilkTea::Parser.parse(source)

    assert_equal source, MilkTea::PrettyPrinter.format_ast(ast)
  end

  def test_formats_lowered_ir_as_structured_output
    source = <<~MT
      module demo.pretty

      struct Counter:
          value: i32

      def main() -> i32:
          var counter = Counter(value = 3)
          let counter_ptr = raw(addr(counter))
          unsafe:
              value(counter_ptr).value = 7
          return counter.value
    MT

    output = with_program(source) do |program|
      MilkTea::PrettyPrinter.format_ir(MilkTea::Lowering.lower(program))
    end

    assert_includes output, "program demo.pretty"
    assert_includes output, "struct Counter as demo_pretty_Counter:"
    assert_includes output, "fn main() -> i32 [entry]:"
    assert_includes output, "let counter_ptr: ptr[demo.pretty.Counter] = cast[ptr[demo.pretty.Counter]](&counter)"
    assert_includes output, "(*counter_ptr).value = 7"
    assert_includes output, "return counter.value"
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
