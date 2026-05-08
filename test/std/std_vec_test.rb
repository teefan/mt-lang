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
      "function main() -> int:",
      "    var items = vec.Vec[int].create()",
      "    defer items.release()",
      "",
      "    items.push(4)",
      "    items.push(7)",
      "    items.push(9)",
      "    items.set(1, 6)",
      "",
      "    if items.count() != 3:",
      "        return 1",
      "    if items.capacity() < 3:",
      "        return 2",
      "",
      "    let total = items.get(0) + items.get(1) + items.get(2)",
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
      "import std.maybe as maybe",
      "import std.vec as vec",
      "",
      "function main() -> int:",
      "    var items = vec.Vec[int].with_capacity(2)",
      "    defer items.release()",
      "",
      "    items.push(3)",
      "    items.push(5)",
      "    items.push(8)",
      "    items.push(13)",
      "",
      "    let removed = items.remove_ordered(1)",
      "    let swapped = items.remove_swap(0)",
      "    let popped = items.pop()",
      "    if maybe.is_none(popped):",
      "        return 1",
      "    if items.count() != 1:",
      "        return 2",
      "",
      "    match popped:",
      "        maybe.Maybe.none:",
      "            return 1",
      "        maybe.Maybe.some as payload:",
      "            let total = removed + swapped + payload.value + items.get(0)",
      "            return total",
      "    return 1",
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
      "",
      "function sum(values: span[int]) -> int:",
      "    var total = 0",
      "    var index: ptr_uint = 0",
      "    while index < values.len:",
      "        unsafe:",
      "            total += read(values.data + index)",
      "        index += 1",
      "    return total",
      "",
      "function main() -> int:",
      "    var items = vec.Vec[int].create()",
      "    defer items.release()",
      "    items.push(10)",
      "    items.push(20)",
      "    items.push(30)",
      "    let total = sum(items.as_span())",
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
