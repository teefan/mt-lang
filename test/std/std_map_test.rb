# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMapTest < Minitest::Test
  def test_host_runtime_executes_map_basic_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.map as map",
      "import std.maybe as maybe",
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
      "function read_int(value: ptr[int]?) -> int:",
      "    if value == null:",
      "        return -1",
      "    unsafe:",
      "        return read(ptr[int]<-value)",
      "",
      "function main() -> int:",
      "    var values = map.Map[Key, int].with_capacity(4)",
      "    defer values.release()",
      "",
      "    let first_key = Key(value = 1)",
      "    let second_key = Key(value = 2)",
      "",
      "    if values.capacity() < 4:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.get(first_key) != null:",
      "        return 3",
      "",
      "    let inserted = values.set(first_key, 10)",
      "    match inserted:",
      "        maybe.Maybe.none:",
      "            if false:",
      "                return 21",
      "        maybe.Maybe.some:",
      "            return 4",
      "",
      "    if values.len() != 1:",
      "        return 5",
      "    if not values.contains(first_key):",
      "        return 6",
      "    if read_int(values.get(first_key)) != 10:",
      "        return 7",
      "",
      "    let replaced = values.set(first_key, 15)",
      "    match replaced:",
      "        maybe.Maybe.none:",
      "            return 8",
      "        maybe.Maybe.some as payload:",
      "            if payload.value != 10:",
      "                return 9",
      "",
      "    if read_int(values.get(first_key)) != 15:",
      "        return 10",
      "",
      "    let second_insert = values.set(second_key, 20)",
      "    match second_insert:",
      "        maybe.Maybe.none:",
      "            if false:",
      "                return 22",
      "        maybe.Maybe.some:",
      "            return 11",
      "",
      "    if values.len() != 2:",
      "        return 12",
      "    if read_int(values.get(second_key)) != 20:",
      "        return 13",
      "",
      "    let removed = values.remove(first_key)",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return 14",
      "        maybe.Maybe.some as payload:",
      "            if payload.value != 15:",
      "                return 15",
      "",
      "    if values.contains(first_key):",
      "        return 16",
      "    if values.len() != 1:",
      "        return 17",
      "",
      "    let missing = values.remove(first_key)",
      "    match missing:",
      "        maybe.Maybe.none:",
      "            if false:",
      "                return 23",
      "        maybe.Maybe.some:",
      "            return 18",
      "",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 19",
      "    if values.capacity() < 4:",
      "        return 20",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_map_growth_and_collisions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.map as map",
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
      "function read_int(value: ptr[int]?) -> int:",
      "    if value == null:",
      "        return -1",
      "    unsafe:",
      "        return read(ptr[int]<-value)",
      "",
      "function main() -> int:",
      "    var values = map.Map[Key, int].create()",
      "    defer values.release()",
      "",
      "    var index: int = 0",
      "    while index < 12:",
      "        let previous = values.set(Key(value = index), index * 10)",
      "        match previous:",
      "            maybe.Maybe.none:",
      "                if false:",
      "                    return 10",
      "            maybe.Maybe.some:",
      "                return 1",
      "        index += 1",
      "",
      "    if values.len() != 12:",
      "        return 2",
      "    if values.capacity() < 12:",
      "        return 3",
      "",
      "    index = 0",
      "    while index < 12:",
      "        if read_int(values.get(Key(value = index))) != index * 10:",
      "            return 4",
      "        index += 1",
      "",
      "    let removed = values.remove(Key(value = 5))",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return 5",
      "        maybe.Maybe.some as payload:",
      "            if payload.value != 50:",
      "                return 6",
      "",
      "    if values.get(Key(value = 5)) != null:",
      "        return 7",
      "    if read_int(values.get(Key(value = 4))) != 40:",
      "        return 8",
      "    if read_int(values.get(Key(value = 6))) != 60:",
      "        return 9",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_map_iterators_and_get_or_insert
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.map as map",
      "import std.maybe as maybe",
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
      "function read_int(value: ptr[int]?) -> int:",
      "    if value == null:",
      "        return -1",
      "    unsafe:",
      "        return read(ptr[int]<-value)",
      "",
      "function main() -> int:",
      "    var values = map.Map[Key, int].create()",
      "    defer values.release()",
      "",
      "    let inserted = values.get_or_insert(Key(value = 3), 30)",
      "    unsafe:",
      "        if read(inserted) != 30:",
      "            return 1",
      "        read(inserted) = 31",
      "",
      "    let existing = values.get_or_insert(Key(value = 3), 99)",
      "    unsafe:",
      "        if read(existing) != 31:",
      "            return 2",
      "",
      "    let removed = values.remove_entry(Key(value = 3))",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return 8",
      "        maybe.Maybe.some as payload:",
      "            if payload.value.key.value != 3:",
      "                return 9",
      "            if payload.value.value != 31:",
      "                return 10",
      "",
      "    if values.contains(Key(value = 3)):",
      "        return 11",
      "",
      "    values.set(Key(value = 1), 10)",
      "    values.set(Key(value = 2), 20)",
      "",
      "    let stored_key = values.get_key(Key(value = 2))",
      "    if stored_key == null:",
      "        return 3",
      "    unsafe:",
      "        if read(ptr[Key]<-stored_key).value != 2:",
      "            return 4",
      "",
      "    var key_total = 0",
      "    for key in values.keys():",
      "        unsafe:",
      "            key_total += read(ptr[Key]<-key).value",
      "    if key_total != 3:",
      "        return 5",
      "",
      "    var value_total = 0",
      "    for value in values.values():",
      "        unsafe:",
      "            value_total += read(value)",
      "    if value_total != 30:",
      "        return 6",
      "",
      "    var entry_total = 0",
      "    for entry in values:",
      "        unsafe:",
      "            entry_total += read(ptr[Key]<-entry.key).value",
      "            entry_total += read(entry.value)",
      "    if entry_total != 33:",
      "        return 12",
      "",
      "    var current_total = 0",
      "    var entries = values.entries()",
      "    while entries.next():",
      "        let entry = entries.current()",
      "        unsafe:",
      "            current_total += read(ptr[Key]<-entry.key).value",
      "            if read(entry.value) == 20:",
      "                read(entry.value) = 21",
      "            current_total += read(entry.value)",
      "    if current_total != 34:",
      "        return 13",
      "",
      "    for value in values.values():",
      "        unsafe:",
      "            if read(value) == 10:",
      "                read(value) = 11",
      "",
      "    if read_int(values.get(Key(value = 1))) != 11:",
      "        return 7",
      "    if read_int(values.get(Key(value = 2))) != 21:",
      "        return 14",
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
    Dir.mktmpdir("milk-tea-std-map") do |dir|
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
