# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMemArenaTest < Minitest::Test
  def test_host_runtime_executes_arena_lifetime_flow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_arena",
      "",
      "import std.mem.arena as arena",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(32)",
      "    defer scratch.release()",
      "",
      "    let start = scratch.mark()",
      "    if start != 0:",
      "        return 1",
      "",
      "    let first = scratch.alloc_bytes(8)",
      "    let after_first = scratch.mark()",
      "    let second = scratch.alloc_bytes(16)",
      "    if first == null or second == null:",
      "        return 2",
      "",
      "    if after_first != 8:",
      "        return 3",
      "",
      "    if scratch.remaining_bytes() != 8:",
      "        return 4",
      "",
      "    scratch.reset(after_first)",
      "    if scratch.remaining_bytes() != 24:",
      "        return 5",
      "",
      "    scratch.reset(start)",
      "    if scratch.remaining_bytes() != 32:",
      "        return 6",
      "",
      "    let too_big = scratch.alloc_bytes(64)",
      "    if too_big != null:",
      "        return 7",
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

  def test_host_runtime_executes_typed_arena_allocation_helper
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_mem_arena_typed",
      "",
      "import std.mem.arena as arena",
      "",
      "struct Pair:",
      "    left: i32",
      "    right: i32",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(usize<-sizeof(Pair))",
      "    defer scratch.release()",
      "",
      "    let pair = arena.alloc[Pair](ref_of(scratch), 1)",
      "    if pair == null:",
      "        return 1",
      "",
      "    unsafe:",
      "        let base = ptr[Pair]<-pair",
      "        base.left = 7",
      "        base.right = 3",
      "        if base.left + base.right != 10:",
      "            return 2",
      "",
      "    let exhausted = arena.alloc[Pair](ref_of(scratch), 1)",
      "    if exhausted != null:",
      "        return 3",
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
    Dir.mktmpdir("milk-tea-std-mem-arena") do |dir|
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
