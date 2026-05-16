# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdCounterTest < Minitest::Test
  def test_host_runtime_executes_counter_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.counter as counter",
      "import std.maybe as maybe",
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
      "    var values = counter.Counter[Key].with_capacity(2)",
      "    defer values.release()",
      "",
      "    if values.capacity() < 2:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.count(Key(value = 3)) != 0:",
      "        return 3",
      "",
      "    if values.add(Key(value = 3), 2) != 2:",
      "        return 4",
      "    if values.increment(Key(value = 1)) != 1:",
      "        return 5",
      "    if values.add(Key(value = 4), 3) != 3:",
      "        return 6",
      "    if values.increment(Key(value = 1)) != 2:",
      "        return 7",
      "    if values.increment(Key(value = 2)) != 1:",
      "        return 8",
      "",
      "    if values.len() != 4:",
      "        return 9",
      "    if values.total_count() != 8:",
      "        return 10",
      "    if values.count(Key(value = 4)) != 3:",
      "        return 11",
      "    if not values.contains(Key(value = 2)):",
      "        return 12",
      "",
      "    var key_step = 0",
      "    for key in values.keys():",
      "        unsafe:",
      "            let current = read(ptr[Key]<-key).value",
      "            if key_step == 0 and current != 3:",
      "                return 13",
      "            if key_step == 1 and current != 1:",
      "                return 14",
      "            if key_step == 2 and current != 4:",
      "                return 15",
      "            if key_step == 3 and current != 2:",
      "                return 16",
      "        key_step += 1",
      "    if key_step != 4:",
      "        return 17",
      "",
      "    var count_total: ptr_uint = 0",
      "    for count in values.counts():",
      "        count_total += count",
      "    if count_total != 8:",
      "        return 18",
      "",
      "    var entry_total = 0",
      "    for entry in values:",
      "        unsafe:",
      "            let current_key = read(ptr[Key]<-entry.key).value",
      "            entry_total += current_key",
      "            entry_total += int<-entry.count",
      "    if entry_total != 18:",
      "        return 19",
      "    if values.total_count() != 8:",
      "        return 20",
      "",
      "    if not values.remove_one(Key(value = 3)):",
      "        return 21",
      "    if values.count(Key(value = 3)) != 1:",
      "        return 22",
      "    if values.total_count() != 7:",
      "        return 23",
      "",
      "    if not values.remove_one(Key(value = 3)):",
      "        return 24",
      "    if values.contains(Key(value = 3)):",
      "        return 25",
      "    if values.total_count() != 6:",
      "        return 26",
      "",
      "    if values.increment(Key(value = 3)) != 1:",
      "        return 27",
      "",
      "    var iter = values.entries()",
      "    var iter_step = 0",
      "    while iter.next():",
      "        let entry = iter.current()",
      "        unsafe:",
      "            let current = read(ptr[Key]<-entry.key).value",
      "            if iter_step == 0 and current != 1:",
      "                return 28",
      "            if iter_step == 1 and current != 4:",
      "                return 29",
      "            if iter_step == 2 and current != 2:",
      "                return 30",
      "            if iter_step == 3 and current != 3:",
      "                return 31",
      "        iter_step += 1",
      "    if iter_step != 4:",
      "        return 32",
      "",
      "    let removed = values.remove(Key(value = 4))",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return 33",
      "        maybe.Maybe.some as payload:",
      "            if payload.value != 3:",
      "                return 34",
      "",
      "    if values.total_count() != 4:",
      "        return 35",
      "    if values.remove_one(Key(value = 9)):",
      "        return 36",
      "",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 37",
      "    if values.len() != 0:",
      "        return 38",
      "    if values.capacity() < 2:",
      "        return 39",
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
    Dir.mktmpdir("milk-tea-std-counter") do |dir|
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
