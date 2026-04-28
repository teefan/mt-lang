# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

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
      "def hash_u64(value: u64) -> u64:",
      "    return hash.u64_value(value)",
      "",
      "def equal_u64(left: u64, right: u64) -> bool:",
      "    return hash.u64_equal(left, right)",
      "",
      "def main() -> i32:",
      "    var scores = map.create[u64, i32](hash_u64, equal_u64)",
      "    defer map.release[u64, i32](addr(scores))",
      "",
      "    map.put[u64, i32](addr(scores), 1, 10)",
      "    map.put[u64, i32](addr(scores), 2, 20)",
      "    map.put[u64, i32](addr(scores), 1, 15)",
      "",
      "    var first = 0",
      "    var second = 0",
      "    if not map.get_into[u64, i32](scores, 1, addr(first)):",
      "        return 1",
      "    if not map.get_into[u64, i32](scores, 2, addr(second)):",
      "        return 2",
      "    if map.contains[u64, i32](scores, 3):",
      "        return 3",
      "    if not map.remove[u64, i32](addr(scores), 1):",
      "        return 4",
      "    if map.contains[u64, i32](scores, 1):",
      "        return 5",
      "",
      "    let total = first + second + cast[i32](map.count[u64, i32](scores))",
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
      "def hash_text(value: str) -> u64:",
      "    return hash.str_value(value)",
      "",
      "def equal_text(left: str, right: str) -> bool:",
      "    return hash.str_equal(left, right)",
      "",
      "def hash_i32(value: i32) -> u64:",
      "    return hash.i32_value(value)",
      "",
      "def equal_i32(left: i32, right: i32) -> bool:",
      "    return hash.i32_equal(left, right)",
      "",
      "def main() -> i32:",
      "    var names = map.create[str, i32](hash_text, equal_text)",
      "    defer map.release[str, i32](addr(names))",
      "    var ids = set.create[i32](hash_i32, equal_i32)",
      "    defer set.release[i32](addr(ids))",
      "",
      "    map.put[str, i32](addr(names), \"tea\", 7)",
      "    map.put[str, i32](addr(names), \"milk\", 5)",
      "    set.add[i32](addr(ids), 10)",
      "    set.add[i32](addr(ids), 20)",
      "    set.add[i32](addr(ids), 10)",
      "",
      "    var tea = 0",
      "    if not map.get_into[str, i32](names, \"tea\", addr(tea)):",
      "        return 1",
      "    if not set.contains[i32](ids, 20):",
      "        return 2",
      "    if not set.remove[i32](addr(ids), 10):",
      "        return 3",
      "    if set.contains[i32](ids, 10):",
      "        return 4",
      "",
      "    let total = tea + cast[i32](set.count[i32](ids))",
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
