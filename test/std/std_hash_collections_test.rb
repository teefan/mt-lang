# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdHashCollectionsTest < Minitest::Test
  def test_host_runtime_executes_hash_map_put_get_update_remove
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_hash_map",
      "",
      "import std.hash as hash",
      "import std.map as map",
      "",
      "def hash_ulong(value: ulong) -> ulong:",
      "    return hash.ulong_value(value)",
      "",
      "def equal_ulong(left: ulong, right: ulong) -> bool:",
      "    return hash.ulong_equal(left, right)",
      "",
      "def main() -> int:",
      "    var scores = map.create[ulong, int](hash_ulong, equal_ulong)",
      "    defer map.release[ulong, int](ref_of(scores))",
      "",
      "    map.put[ulong, int](ref_of(scores), 1, 10)",
      "    map.put[ulong, int](ref_of(scores), 2, 20)",
      "    map.put[ulong, int](ref_of(scores), 1, 15)",
      "",
      "    var first = 0",
      "    var second = 0",
      "    if not map.get_into[ulong, int](scores, 1, ref_of(first)):",
      "        return 1",
      "    if not map.get_into[ulong, int](scores, 2, ref_of(second)):",
      "        return 2",
      "    if map.contains[ulong, int](scores, 3):",
      "        return 3",
      "    if not map.remove[ulong, int](ref_of(scores), 1):",
      "        return 4",
      "    if map.contains[ulong, int](scores, 1):",
      "        return 5",
      "",
      "    let total = first + second + int<-map.count[ulong, int](scores)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 36, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_hash_map_with_string_keys_and_hash_set
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_hash_set",
      "",
      "import std.hash as hash",
      "import std.map as map",
      "import std.set as set",
      "",
      "def hash_text(value: str) -> ulong:",
      "    return hash.str_value(value)",
      "",
      "def equal_text(left: str, right: str) -> bool:",
      "    return hash.str_equal(left, right)",
      "",
      "def hash_int(value: int) -> ulong:",
      "    return hash.int_value(value)",
      "",
      "def equal_int(left: int, right: int) -> bool:",
      "    return hash.int_equal(left, right)",
      "",
      "def main() -> int:",
      "    var names = map.create[str, int](hash_text, equal_text)",
      "    defer map.release[str, int](ref_of(names))",
      "    var ids = set.create[int](hash_int, equal_int)",
      "    defer set.release[int](ref_of(ids))",
      "",
      "    map.put[str, int](ref_of(names), \"tea\", 7)",
      "    map.put[str, int](ref_of(names), \"milk\", 5)",
      "    set.add[int](ref_of(ids), 10)",
      "    set.add[int](ref_of(ids), 20)",
      "    set.add[int](ref_of(ids), 10)",
      "",
      "    var tea = 0",
      "    if not map.get_into[str, int](names, \"tea\", ref_of(tea)):",
      "        return 1",
      "    if not set.contains[int](ids, 20):",
      "        return 2",
      "    if not set.remove[int](ref_of(ids), 10):",
      "        return 3",
      "    if set.contains[int](ids, 10):",
      "        return 4",
      "",
      "    let total = tea + int<-set.count[int](ids)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 8, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-hash-collections") do |dir|
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
