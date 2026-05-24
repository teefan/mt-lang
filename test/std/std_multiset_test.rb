# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiSetTest < Minitest::Test
  def test_host_runtime_executes_multiset_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.multiset as multiset

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-(read(ptr[Key]<-value).value & 1)

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value

function main() -> int:
    var values = multiset.MultiSet[Key].with_capacity(2)
    defer values.release()

    if values.capacity() < 2:
        return 1
    if not values.is_empty():
        return 2
    if values.len() != 0:
        return 3
    if values.distinct_len() != 0:
        return 4

    if values.insert(Key(value = 3)) != 1:
        return 5
    if values.add(Key(value = 1), 2) != 2:
        return 6
    if values.add(Key(value = 4), 3) != 3:
        return 7
    if values.insert(Key(value = 1)) != 3:
        return 8
    if values.insert(Key(value = 2)) != 1:
        return 9

    if values.len() != 8:
        return 10
    if values.total_count() != 8:
        return 11
    if values.distinct_len() != 4:
        return 12
    if values.count(Key(value = 1)) != 3:
        return 13
    if not values.contains(Key(value = 2)):
        return 14

    var value_step = 0
    for value in values.values():
        unsafe:
            let current = read(ptr[Key]<-value).value
            if value_step == 0 and current != 3:
                return 15
            if value_step == 1 and current != 1:
                return 16
            if value_step == 2 and current != 4:
                return 17
            if value_step == 3 and current != 2:
                return 18
        value_step += 1
    if value_step != 4:
        return 19

    var entry_step = 0
    var count_total: ptr_uint = 0
    for entry in values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if entry_step == 0 and (current != 3 or entry.count != 1):
                return 20
            if entry_step == 1 and (current != 1 or entry.count != 3):
                return 21
            if entry_step == 2 and (current != 4 or entry.count != 3):
                return 22
            if entry_step == 3 and (current != 2 or entry.count != 1):
                return 23
        count_total += entry.count
        entry_step += 1
    if entry_step != 4:
        return 24
    if count_total != 8:
        return 25

    if not values.remove_one(Key(value = 1)):
        return 26
    if values.count(Key(value = 1)) != 2:
        return 27
    if values.total_count() != 7:
        return 28

    let removed = values.remove_all(Key(value = 4))
    match removed:
        Option.none:
            return 29
        Option.some as payload:
            if payload.value != 3:
                return 30

    if values.total_count() != 4:
        return 31
    if values.distinct_len() != 3:
        return 32
    if values.remove_one(Key(value = 9)):
        return 33

    var other = multiset.MultiSet[Key].create()
    defer other.release()
    other.add(Key(value = 3), 4)
    other.add(Key(value = 1), 1)
    other.add(Key(value = 2), 1)
    other.insert(Key(value = 5))

    var union_values = values.union_with(other)
    defer union_values.release()
    var union_step = 0
    for entry in union_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if union_step == 0 and (current != 3 or entry.count != 4):
                return 34
            if union_step == 1 and (current != 1 or entry.count != 2):
                return 35
            if union_step == 2 and (current != 2 or entry.count != 1):
                return 36
            if union_step == 3 and (current != 5 or entry.count != 1):
                return 37
        union_step += 1
    if union_step != 4:
        return 38

    var intersection_values = values.intersection(other)
    defer intersection_values.release()
    var intersection_step = 0
    for entry in intersection_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if intersection_step == 0 and (current != 3 or entry.count != 1):
                return 39
            if intersection_step == 1 and (current != 1 or entry.count != 1):
                return 40
            if intersection_step == 2 and (current != 2 or entry.count != 1):
                return 41
        intersection_step += 1
    if intersection_step != 3:
        return 42

    var difference_values = values.difference(other)
    defer difference_values.release()
    var difference_step = 0
    for entry in difference_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if difference_step == 0 and (current != 1 or entry.count != 1):
                return 43
        difference_step += 1
    if difference_step != 1:
        return 44

    if not values.is_subset(other.union_with(values)):
        return 45
    if other.is_subset(values):
        return 46

    var symmetric_values = values.symmetric_difference(other)
    defer symmetric_values.release()
    var symmetric_step = 0
    for entry in symmetric_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if symmetric_step == 0 and (current != 3 or entry.count != 3):
                return 47
            if symmetric_step == 1 and (current != 1 or entry.count != 1):
                return 48
            if symmetric_step == 2 and (current != 5 or entry.count != 1):
                return 49
        symmetric_step += 1
    if symmetric_step != 3:
        return 50

    values.clear()
    if not values.is_empty():
        return 51
    if values.len() != 0:
        return 52
    if values.distinct_len() != 0:
        return 53
    if values.capacity() < 2:
        return 54
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
    Dir.mktmpdir("milk-tea-std-multiset") do |dir|
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
