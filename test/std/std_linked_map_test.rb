# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLinkedMapTest < Minitest::Test
  def test_host_runtime_executes_linked_map_insertion_order_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.linked_map as linked_map


struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-(read(ptr[Key]<-value).value & 1)

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value

function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)

function main() -> int:
    var values = linked_map.LinkedMap[Key, int].with_capacity(2)
    defer values.release()

    if values.capacity() < 2:
        return 1
    if not values.is_empty():
        return 2

    values.set(Key(value = 3), 30)
    values.set(Key(value = 1), 10)
    values.set(Key(value = 4), 40)
    values.set(Key(value = 2), 20)
    if values.len() != 4:
        return 3

    let replaced = values.set(Key(value = 1), 11)
    match replaced:
        Option.none:
            return 4
        Option.some as payload:
            if payload.value != 10:
                return 5

    let stored_key = values.get_key(Key(value = 2))
    if stored_key == null:
        return 6
    unsafe:
        if read(ptr[Key]<-stored_key).value != 2:
            return 7

    let existing_ptr = values.get_or_insert(Key(value = 4), 99)
    unsafe:
        if read(existing_ptr) != 40:
            return 8
        read(existing_ptr) = 41

    let inserted_ptr = values.get_or_insert(Key(value = 5), 50)
    unsafe:
        if read(inserted_ptr) != 50:
            return 9
        read(inserted_ptr) = 51

    var key_step = 0
    var key_total = 0
    for key in values.keys():
        unsafe:
            let current = read(ptr[Key]<-key).value
            if key_step == 0 and current != 3:
                return 10
            if key_step == 1 and current != 1:
                return 11
            if key_step == 2 and current != 4:
                return 12
            if key_step == 3 and current != 2:
                return 13
            if key_step == 4 and current != 5:
                return 14
            key_total += current
        key_step += 1
    if key_step != 5:
        return 15
    if key_total != 15:
        return 16

    let removed = values.remove_entry(Key(value = 1))
    match removed:
        Option.none:
            return 17
        Option.some as payload:
            if payload.value.key.value != 1:
                return 18
            if payload.value.value != 11:
                return 19

    let reinserted = values.set(Key(value = 1), 15)
    match reinserted:
        Option.none:
            if false:
                return 101
        Option.some as ignored_payload:
            return 20

    var entry_step = 0
    var entry_total = 0
    for entry in values:
        unsafe:
            let current_key = read(ptr[Key]<-entry.key).value
            if entry_step == 0 and current_key != 3:
                return 21
            if entry_step == 1 and current_key != 4:
                return 22
            if entry_step == 2 and current_key != 2:
                return 23
            if entry_step == 3 and current_key != 5:
                return 24
            if entry_step == 4 and current_key != 1:
                return 25
            entry_total += current_key
            entry_total += read(entry.value)
        entry_step += 1
    if entry_step != 5:
        return 26
    if entry_total != 172:
        return 27

    var entries = values.entries()
    var current_total = 0
    while entries.next():
        let entry = entries.current()
        unsafe:
            current_total += read(ptr[Key]<-entry.key).value
            current_total += read(entry.value)
    if current_total != 172:
        return 28

    let removed_value = values.remove(Key(value = 3))
    match removed_value:
        Option.none:
            return 29
        Option.some as payload:
            if payload.value != 30:
                return 30

    if values.contains(Key(value = 3)):
        return 31
    if read_int(values.get(Key(value = 4))) != 41:
        return 32

    values.clear()
    if not values.is_empty():
        return 33
    if values.capacity() < 2:
        return 34
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-linked-map") do |dir|
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
