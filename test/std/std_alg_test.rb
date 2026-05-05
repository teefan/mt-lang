# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdAlgTest < Minitest::Test
  def test_host_runtime_executes_search_and_predicates
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_alg_search",
      "",
      "import std.alg as alg",
      "import std.span as sp",
      "",
      "def equal_int(left: int, right: int) -> bool:",
      "    return left == right",
      "",
      "def even(value: int) -> bool:",
      "    return value % 2 == 0",
      "",
      "def positive(value: int) -> bool:",
      "    return value > 0",
      "",
      "def above_four(value: int) -> bool:",
      "    return value > 4",
      "",
      "def main() -> int:",
      "    var values = array[int, 5](1, 2, 4, 5, 6)",
      "    let items = sp.from_ptr[int](ptr_of(values[0]), 5)",
      "    var found_index: ptr_uint = 0",
      "    if not alg.index_of[int](items, 4, equal_int, ref_of(found_index)):",
      "        return 1",
      "    if alg.contains[int](items, 7, equal_int):",
      "        return 2",
      "    if not alg.any[int](items, above_four):",
      "        return 3",
      "    if not alg.all[int](items, positive):",
      "        return 4",
      "    let total = int<-found_index + int<-alg.count_if[int](items, even)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 5, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_copy_fill_equal_and_sort
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_alg_sort",
      "",
      "import std.alg as alg",
      "import std.span as sp",
      "",
      "def equal_int(left: int, right: int) -> bool:",
      "    return left == right",
      "",
      "def less_int(left: int, right: int) -> bool:",
      "    return left < right",
      "",
      "def main() -> int:",
      "    var source_values = array[int, 4](5, 1, 4, 3)",
      "    var target_values = array[int, 4](0, 0, 0, 0)",
      "    let source = sp.from_ptr[int](ptr_of(source_values[0]), 4)",
      "    let target = sp.from_ptr[int](ptr_of(target_values[0]), 4)",
      "",
      "    alg.fill[int](target, 9)",
      "    let copied = alg.copy[int](target, source)",
      "    if not alg.equal[int](source, target, equal_int):",
      "        return 1",
      "",
      "    alg.sort[int](target, less_int)",
      "    let total = target[0] + target[1] * 2 + target[2] * 3 + target[3] * 4 + int<-copied",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 43, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-alg") do |dir|
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
