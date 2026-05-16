# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdSetTest < Minitest::Test
  def test_host_runtime_executes_set_basic_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.set as set",
      "",
      "struct Key:",
      "    value: int",
      "",
      "methods Key:",
      "    static function hash(value: const_ptr[Key]) -> uint:",
      "        unsafe:",
      "            return uint<-read(ptr[Key]<-value).value",
      "",
      "    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:",
      "        unsafe:",
      "            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value",
      "",
      "function main() -> int:",
      "    var values = set.Set[Key].with_capacity(4)",
      "    defer values.release()",
      "",
      "    if values.capacity() < 4:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.contains(Key(value = 1)):",
      "        return 3",
      "",
      "    if not values.insert(Key(value = 1)):",
      "        return 4",
      "    if values.insert(Key(value = 1)):",
      "        return 5",
      "    if not values.insert(Key(value = 2)):",
      "        return 6",
      "",
      "    if values.len() != 2:",
      "        return 7",
      "    if not values.contains(Key(value = 2)):",
      "        return 8",
      "",
      "    let stored = values.get(Key(value = 2))",
      "    if stored == null:",
      "        return 9",
      "    unsafe:",
      "        if read(ptr[Key]<-stored).value != 2:",
      "            return 10",
      "",
      "    if values.remove(Key(value = 3)):",
      "        return 11",
      "    if not values.remove(Key(value = 1)):",
      "        return 12",
      "    if values.contains(Key(value = 1)):",
      "        return 13",
      "    if values.len() != 1:",
      "        return 14",
      "",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 15",
      "    if values.capacity() < 4:",
      "        return 16",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_set_growth_and_iteration
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.set as set",
      "",
      "struct Key:",
      "    value: int",
      "",
      "methods Key:",
      "    static function hash(value: const_ptr[Key]) -> uint:",
      "        unsafe:",
      "            return uint<-(read(ptr[Key]<-value).value & 1)",
      "",
      "    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:",
      "        unsafe:",
      "            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value",
      "",
      "function main() -> int:",
      "    var values = set.Set[Key].create()",
      "    defer values.release()",
      "",
      "    var index: int = 0",
      "    while index < 12:",
      "        if not values.insert(Key(value = index)):",
      "            return 1",
      "        index += 1",
      "",
      "    if values.len() != 12:",
      "        return 2",
      "    if values.capacity() < 12:",
      "        return 3",
      "",
      "    var total = 0",
      "    var count = 0",
      "    for value in values:",
      "        unsafe:",
      "            total += read(ptr[Key]<-value).value",
      "        count += 1",
      "",
      "    if count != 12:",
      "        return 4",
      "    if total != 66:",
      "        return 5",
      "",
      "    var iter = values.iter()",
      "    var manual_total = 0",
      "    var manual_count = 0",
      "    while true:",
      "        let value = iter.next()",
      "        if value == null:",
      "            break",
      "        unsafe:",
      "            manual_total += read(ptr[Key]<-value).value",
      "        manual_count += 1",
      "",
      "    if manual_count != 12:",
      "        return 9",
      "    if manual_total != 66:",
      "        return 10",
      "",
      "    if not values.remove(Key(value = 5)):",
      "        return 6",
      "    if values.contains(Key(value = 5)):",
      "        return 7",
      "    if values.len() != 11:",
      "        return 8",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_set_algebra_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.set as set",
      "",
      "struct Key:",
      "    value: int",
      "",
      "methods Key:",
      "    static function hash(value: const_ptr[Key]) -> uint:",
      "        unsafe:",
      "            return uint<-read(ptr[Key]<-value).value",
      "",
      "    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:",
      "        unsafe:",
      "            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value",
      "",
      "function main() -> int:",
      "    var left = set.Set[Key].create()",
      "    defer left.release()",
      "    var right = set.Set[Key].create()",
      "    defer right.release()",
      "    var subset = set.Set[Key].create()",
      "    defer subset.release()",
      "",
      "    left.insert(Key(value = 1))",
      "    left.insert(Key(value = 2))",
      "    left.insert(Key(value = 3))",
      "    right.insert(Key(value = 3))",
      "    right.insert(Key(value = 4))",
      "    subset.insert(Key(value = 1))",
      "    subset.insert(Key(value = 3))",
      "",
      "    if not subset.is_subset(left):",
      "        return 1",
      "    if right.is_subset(left):",
      "        return 2",
      "",
      "    var union_values = left.union_with(right)",
      "    defer union_values.release()",
      "    if union_values.len() != 4:",
      "        return 3",
      "    if not union_values.contains(Key(value = 1)):",
      "        return 4",
      "    if not union_values.contains(Key(value = 4)):",
      "        return 5",
      "",
      "    var intersection_values = left.intersection(right)",
      "    defer intersection_values.release()",
      "    if intersection_values.len() != 1:",
      "        return 6",
      "    if not intersection_values.contains(Key(value = 3)):",
      "        return 7",
      "    if not intersection_values.is_subset(left):",
      "        return 8",
      "",
      "    var difference_values = left.difference(right)",
      "    defer difference_values.release()",
      "    if difference_values.len() != 2:",
      "        return 9",
      "    if not difference_values.contains(Key(value = 1)):",
      "        return 10",
      "    if difference_values.contains(Key(value = 3)):",
      "        return 11",
      "",
      "    if left.len() != 3:",
      "        return 12",
      "    if right.len() != 2:",
      "        return 13",
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
    Dir.mktmpdir("milk-tea-std-set") do |dir|
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
