# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdMemStackTest < Minitest::Test
  def test_host_runtime_executes_stack_temporary_flow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_stack",
      "",
      "import std.mem.stack as stack",
      "",
      "def main() -> i32:",
      "    var temp = stack.create(24)",
      "    defer temp.release()",
      "",
      "    let start = temp.mark()",
      "    let first = temp.alloc_bytes(8)",
      "    let nested = temp.mark()",
      "    let second = temp.alloc_bytes(8)",
      "    if first == null or second == null:",
      "        return 1",
      "",
      "    temp.reset(nested)",
      "    if temp.remaining_bytes() != 16:",
      "        return 2",
      "",
      "    temp.reset(start)",
      "    if temp.remaining_bytes() != 24:",
      "        return 3",
      "",
      "    let too_big = temp.alloc_bytes(32)",
      "    if too_big != null:",
      "        return 4",
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
    Dir.mktmpdir("milk-tea-std-mem-stack") do |dir|
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
