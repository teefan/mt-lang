# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdLinkedSetTest < Minitest::Test
  def test_host_runtime_executes_linked_set_insertion_order_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.linked_set as linked_set

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
    var values = linked_set.LinkedSet[Key].with_capacity(2)
    defer values.release()

    if values.capacity() < 2:
        return 1
    if not values.insert(Key(value = 3)):
        return 2
    if not values.insert(Key(value = 1)):
        return 3
    if not values.insert(Key(value = 4)):
        return 4
    if not values.insert(Key(value = 2)):
        return 5
    if values.insert(Key(value = 1)):
        return 6

    let stored = values.get(Key(value = 2))
    if stored == null:
        return 7
    unsafe:
        if read(ptr[Key]<-stored).value != 2:
            return 8

    var step = 0
    for value in values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if step == 0 and current != 3:
                return 9
            if step == 1 and current != 1:
                return 10
            if step == 2 and current != 4:
                return 11
            if step == 3 and current != 2:
                return 12
        step += 1
    if step != 4:
        return 13

    if not values.remove(Key(value = 1)):
        return 14
    if not values.insert(Key(value = 1)):
        return 15

    var iter = values.iter()
    var iter_step = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            let current = read(ptr[Key]<-value).value
            if iter_step == 0 and current != 3:
                return 16
            if iter_step == 1 and current != 4:
                return 17
            if iter_step == 2 and current != 2:
                return 18
            if iter_step == 3 and current != 1:
                return 19
        iter_step += 1
    if iter_step != 4:
        return 20

    var other = linked_set.LinkedSet[Key].create()
    defer other.release()
    other.insert(Key(value = 2))
    other.insert(Key(value = 5))
    other.insert(Key(value = 1))

    var union_values = values.union_with(other)
    defer union_values.release()
    var union_step = 0
    for value in union_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if union_step == 0 and current != 3:
                return 21
            if union_step == 1 and current != 4:
                return 22
            if union_step == 2 and current != 2:
                return 23
            if union_step == 3 and current != 1:
                return 24
            if union_step == 4 and current != 5:
                return 25
        union_step += 1
    if union_step != 5:
        return 26

    var intersection_values = values.intersection(other)
    defer intersection_values.release()
    var intersection_step = 0
    for value in intersection_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if intersection_step == 0 and current != 2:
                return 27
            if intersection_step == 1 and current != 1:
                return 28
        intersection_step += 1
    if intersection_step != 2:
        return 29

    var difference_values = values.difference(other)
    defer difference_values.release()
    var difference_step = 0
    for value in difference_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if difference_step == 0 and current != 3:
                return 30
            if difference_step == 1 and current != 4:
                return 31
        difference_step += 1
    if difference_step != 2:
        return 32

    var subset = linked_set.LinkedSet[Key].create()
    defer subset.release()
    subset.insert(Key(value = 3))
    subset.insert(Key(value = 1))
    if not subset.is_subset(values):
        return 33
    if other.is_subset(values):
        return 34

    values.clear()
    if not values.is_empty():
        return 35
    if values.capacity() < 2:
        return 36
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
    Dir.mktmpdir("milk-tea-std-linked-set") do |dir|
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
