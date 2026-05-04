# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdSpanTest < Minitest::Test
  def test_host_runtime_executes_span_pointer_constructors
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_span_constructors",
      "",
      "import std.span as sp",
      "",
      "def sum(values: span[i32]) -> i32:",
      "    var total = 0",
      "    var index: usize = 0",
      "    while index < values.len:",
      "        unsafe:",
      "            total += read(values.data + index)",
      "        index += 1",
      "    return total",
      "",
      "def main() -> i32:",
      "    var values = array[i32, 3](7, 8, 9)",
      "    let view = sp.from_ptr[i32](ptr_of(values[0]), 3)",
      "    let empty = sp.empty[i32]()",
      "    var missing: ptr[i32]? = null",
      "    let null_view = sp.from_nullable_ptr[i32](missing, 0)",
      "    if empty.len != 0:",
      "        return 1",
      "    if null_view.len != 0:",
      "        return 2",
      "    return sum(view)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 24, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-span") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
