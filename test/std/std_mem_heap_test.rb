# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMemHeapTest < Minitest::Test
  def test_host_runtime_executes_heap_allocation_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_heap",
      "",
      "import std.mem.heap as heap",
      "",
      "def main() -> int:",
      "    let bytes = heap.alloc[ubyte](16)",
      "    let grown = heap.resize(bytes, 32)",
      "    let zeroed = heap.alloc_zeroed[bool](4)",
      "    let raw = heap.alloc_bytes(8)",
      "    let raw_grown = heap.resize_bytes(raw, 16)",
      "    heap.release(grown)",
      "    heap.release(zeroed)",
      "    heap.release_bytes(raw_grown)",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_heap_contract_edges
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_heap_contracts",
      "",
      "import std.mem.heap as heap",
      "",
      "align(16) struct Mat4:",
      "    data: array[float, 16]",
      "",
      "def main() -> int:",
      "    if heap.alloc_bytes(0) != null:",
      "        return 1",
      "    if heap.alloc_zeroed_bytes(0, 4) != null:",
      "        return 2",
      "",
      "    let raw = heap.alloc_bytes(8)",
      "    if raw == null:",
      "        return 3",
      "    let released = heap.resize_bytes(raw, 0)",
      "    if released != null:",
      "        return 4",
      "",
      "    let aligned = heap.alloc_bytes_aligned(1, 16)",
      "    if aligned == null:",
      "        return 5",
      "    heap.release_bytes(aligned)",
      "",
      "    if heap.alloc[Mat4](1) != null:",
      "        return 6",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-mem-heap") do |dir|
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
