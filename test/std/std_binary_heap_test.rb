# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdBinaryHeapTest < Minitest::Test
  def test_host_runtime_executes_binary_heap_ordered_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary_heap as binary_heap


struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value

function pop_value(values: ref[binary_heap.BinaryHeap[Key]]) -> int:
    let removed = values.pop()
    match removed:
        Option.none:
            return -1
        Option.some as payload:
            return payload.value.value

function main() -> int:
    var values = binary_heap.BinaryHeap[Key].with_capacity(2)
    defer values.release()

    if values.capacity() < 2:
        return 1
    if not values.is_empty():
        return 2
    if values.peek() != null:
        return 3

    values.push(Key(value = 3))
    values.push(Key(value = 1))
    values.push(Key(value = 7))
    values.push(Key(value = 7))
    values.push(Key(value = 2))

    if values.len() != 5:
        return 4
    if values.capacity() < 5:
        return 5

    let top = values.peek()
    if top == null:
        return 6
    unsafe:
        if read(ptr[Key]<-top).value != 7:
            return 7

    var iter = values.iter()
    var iter_total = 0
    var iter_count = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            iter_total += read(ptr[Key]<-value).value
        iter_count += 1

    if iter_count != 5:
        return 8
    if iter_total != 20:
        return 9

    var for_total = 0
    var for_count = 0
    for value in values:
        unsafe:
            for_total += read(ptr[Key]<-value).value
        for_count += 1

    if for_count != 5:
        return 10
    if for_total != 20:
        return 11

    if pop_value(values) != 7:
        return 12
    if pop_value(values) != 7:
        return 13
    if pop_value(values) != 3:
        return 14
    if pop_value(values) != 2:
        return 15
    if pop_value(values) != 1:
        return 16
    if not values.is_empty():
        return 17
    if values.peek() != null:
        return 18

    let missing = values.pop()
    match missing:
        Option.none:
            if false:
                return 19
        Option.some as ignored_payload:
            return 20

    values.push(Key(value = 5))
    values.push(Key(value = 4))
    values.clear()
    if not values.is_empty():
        return 21
    if values.capacity() < 5:
        return 22
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
    Dir.mktmpdir("milk-tea-std-binary-heap") do |dir|
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
