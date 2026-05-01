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
      "def equal_i32(left: i32, right: i32) -> bool:",
      "    return left == right",
      "",
      "def even(value: i32) -> bool:",
      "    return value % 2 == 0",
      "",
      "def positive(value: i32) -> bool:",
      "    return value > 0",
      "",
      "def above_four(value: i32) -> bool:",
      "    return value > 4",
      "",
      "def main() -> i32:",
      "    var values = array[i32, 5](1, 2, 4, 5, 6)",
      "    let items = sp.from_ptr[i32](ptr_of(ref_of(values[0])), 5)",
      "    var found_index: usize = 0",
      "    if not alg.index_of[i32](items, 4, equal_i32, ref_of(found_index)):",
      "        return 1",
      "    if alg.contains[i32](items, 7, equal_i32):",
      "        return 2",
      "    if not alg.any[i32](items, above_four):",
      "        return 3",
      "    if not alg.all[i32](items, positive):",
      "        return 4",
      "    let total = i32<-found_index + i32<-alg.count_if[i32](items, even)",
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
      "def equal_i32(left: i32, right: i32) -> bool:",
      "    return left == right",
      "",
      "def less_i32(left: i32, right: i32) -> bool:",
      "    return left < right",
      "",
      "def main() -> i32:",
      "    var source_values = array[i32, 4](5, 1, 4, 3)",
      "    var target_values = array[i32, 4](0, 0, 0, 0)",
      "    let source = sp.from_ptr[i32](ptr_of(ref_of(source_values[0])), 4)",
      "    let target = sp.from_ptr[i32](ptr_of(ref_of(target_values[0])), 4)",
      "",
      "    alg.fill[i32](target, 9)",
      "    let copied = alg.copy[i32](target, source)",
      "    if not alg.equal[i32](source, target, equal_i32):",
      "        return 1",
      "",
      "    alg.sort[i32](target, less_i32)",
      "    let total = target[0] + target[1] * 2 + target[2] * 3 + target[3] * 4 + i32<-copied",
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
