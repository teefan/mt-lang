# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdVecTest < Minitest::Test
  def test_host_runtime_executes_vec_growth_and_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_vec_growth",
      "",
      "import std.vec as vec",
      "",
      "def main() -> int:",
      "    var items = vec.create[int]()",
      "    defer vec.release[int](ref_of(items))",
      "",
      "    vec.push[int](ref_of(items), 4)",
      "    vec.push[int](ref_of(items), 7)",
      "    vec.push[int](ref_of(items), 9)",
      "    vec.set[int](ref_of(items), 1, 6)",
      "",
      "    if vec.count[int](items) != 3:",
      "        return 1",
      "    if vec.capacity[int](items) < 3:",
      "        return 2",
      "",
      "    let total = vec.get[int](items, 0) + vec.get[int](items, 1) + vec.get[int](items, 2)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 19, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_pop_and_removal
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_vec_remove",
      "",
      "import std.vec as vec",
      "",
      "def main() -> int:",
      "    var items = vec.with_capacity[int](2)",
      "    defer vec.release[int](ref_of(items))",
      "",
      "    vec.push[int](ref_of(items), 3)",
      "    vec.push[int](ref_of(items), 5)",
      "    vec.push[int](ref_of(items), 8)",
      "    vec.push[int](ref_of(items), 13)",
      "",
      "    let removed = vec.remove_ordered[int](ref_of(items), 1)",
      "    let swapped = vec.remove_swap[int](ref_of(items), 0)",
      "    var popped = 0",
      "    if not vec.pop_into[int](ref_of(items), ref_of(popped)):",
      "        return 1",
      "    if vec.count[int](items) != 1:",
      "        return 2",
      "",
      "    let total = removed + swapped + popped + vec.get[int](items, 0)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 29, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_vec_span_view
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_vec_span",
      "",
      "import std.vec as vec",
      "import std.span as sp",
      "",
      "def sum(values: span[int]) -> int:",
      "    var total = 0",
      "    var index: ptr_uint = 0",
      "    while index < values.len:",
      "        unsafe:",
      "            total += read(values.data + index)",
      "        index += 1",
      "    return total",
      "",
      "def main() -> int:",
      "    var items = vec.create[int]()",
      "    defer vec.release[int](ref_of(items))",
      "    vec.push[int](ref_of(items), 10)",
      "    vec.push[int](ref_of(items), 20)",
      "    vec.push[int](ref_of(items), 30)",
      "    let total = sum(sp.from_nullable_ptr[int](vec.data_ptr[int](items), vec.count[int](items)))",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 60, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-vec") do |dir|
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
