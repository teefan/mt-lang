# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdOrderedSetTest < Minitest::Test
  def test_host_runtime_executes_ordered_set_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.ordered_set as ordered_set",
      "",
      "struct Key:",
      "    value: int",
      "",
      "methods Key:",
      "    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:",
      "        unsafe:",
      "            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value",
      "",
      "function main() -> int:",
      "    var values = ordered_set.OrderedSet[Key].create()",
      "    defer values.release()",
      "",
      "    if not values.is_empty():",
      "        return 1",
      "    if values.get(Key(value = 1)) != null:",
      "        return 2",
      "",
      "    var index: int = 0",
      "    while index < 12:",
      "        if not values.insert(Key(value = index)):",
      "            return 3",
      "        index += 1",
      "",
      "    if values.insert(Key(value = 5)):",
      "        return 4",
      "    if values.len() != 12:",
      "        return 5",
      "    if not values.contains(Key(value = 7)):",
      "        return 6",
      "",
      "    let stored = values.get(Key(value = 7))",
      "    if stored == null:",
      "        return 7",
      "    unsafe:",
      "        if read(ptr[Key]<-stored).value != 7:",
      "            return 8",
      "",
      "    var expected = 0",
      "    for value in values:",
      "        unsafe:",
      "            if read(ptr[Key]<-value).value != expected:",
      "                return 9",
      "        expected += 1",
      "",
      "    if expected != 12:",
      "        return 10",
      "",
      "    var iter = values.iter()",
      "    var manual_expected = 0",
      "    while true:",
      "        let value = iter.next()",
      "        if value == null:",
      "            break",
      "        unsafe:",
      "            if read(ptr[Key]<-value).value != manual_expected:",
      "                return 11",
      "        manual_expected += 1",
      "",
      "    if manual_expected != 12:",
      "        return 12",
      "",
      "    if not values.remove(Key(value = 5)):",
      "        return 13",
      "    if not values.remove(Key(value = 0)):",
      "        return 14",
      "    if not values.remove(Key(value = 11)):",
      "        return 15",
      "    if values.remove(Key(value = 5)):",
      "        return 16",
      "    if values.contains(Key(value = 5)):",
      "        return 17",
      "    if values.len() != 9:",
      "        return 18",
      "",
      "    var previous = -1",
      "    var total = 0",
      "    for value in values:",
      "        unsafe:",
      "            let current = read(ptr[Key]<-value).value",
      "            if current <= previous:",
      "                return 19",
      "            previous = current",
      "            total += current",
      "",
      "    if total != 50:",
      "        return 20",
      "",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 21",
      "    if values.get(Key(value = 2)) != null:",
      "        return 22",
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
    Dir.mktmpdir("milk-tea-std-ordered-set") do |dir|
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
