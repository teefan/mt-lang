# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdMemHeapTest < Minitest::Test
  def test_host_runtime_executes_heap_allocation_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_heap",
      "",
      "import std.mem.heap as heap",
      "",
      "def main() -> i32:",
      "    let bytes = heap.alloc(16)",
      "    let grown = heap.resize(bytes, 32)",
      "    let zeroed = heap.alloc_zeroed(4, 8)",
      "    heap.release(grown)",
      "    heap.release(zeroed)",
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
