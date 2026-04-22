# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdMemPoolTest < Minitest::Test
  def test_host_runtime_executes_pool_stable_storage_flow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_pool",
      "",
      "import std.mem.pool as pool",
      "",
      "def main() -> i32:",
      "    var objects = pool.create(8, 2)",
      "    defer objects.release()",
      "",
      "    if objects.remaining_slots() != 2:",
      "        return 1",
      "",
      "    let first = objects.alloc_bytes()",
      "    let second = objects.alloc_bytes()",
      "    let third = objects.alloc_bytes()",
      "    if first == null or second == null:",
      "        return 2",
      "    if third != null:",
      "        return 3",
      "",
      "    if objects.remaining_slots() != 0:",
      "        return 4",
      "",
      "    if not objects.release_bytes(first):",
      "        return 5",
      "    if objects.remaining_slots() != 1:",
      "        return 6",
      "",
      "    let reused = objects.alloc_bytes()",
      "    if reused == null:",
      "        return 7",
      "    if reused != first:",
      "        return 8",
      "",
      "    if not objects.release_bytes(reused):",
      "        return 9",
      "    if objects.release_bytes(reused):",
      "        return 10",
      "    if not objects.release_bytes(second):",
      "        return 11",
      "    if objects.remaining_slots() != 2:",
      "        return 12",
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
    Dir.mktmpdir("milk-tea-std-mem-pool") do |dir|
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
