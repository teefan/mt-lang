# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdDequeTest < Minitest::Test
  def test_host_runtime_executes_deque_storage_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)

function main() -> int:
    var values = deque.Deque[int].with_capacity(1)
    defer values.release()
    if values.capacity() < 1:
        return 1
    if not values.is_empty():
        return 2

    values.push_back(10)
    values.push_back(20)
    values.push_front(5)

    if values.len() != 3:
        return 3
    if read_int(values.first()) != 5:
        return 4
    if read_int(values.get(1)) != 10:
        return 5
    if read_int(values.last()) != 20:
        return 6

    let middle = values.get(1)
    if middle == null:
        return 7
    unsafe:
        read(ptr[int]<-middle) = 12

    if read_int(values.get(1)) != 12:
        return 8

    let front = values.pop_front()
    match front:
        Option.none:
            return 9
        Option.some as payload:
            if payload.value != 5:
                return 10

    let back = values.pop_back()
    match back:
        Option.none:
            return 11
        Option.some as payload:
            if payload.value != 20:
                return 12

    let remaining = values.pop_back()
    match remaining:
        Option.none:
            return 13
        Option.some as payload:
            if payload.value != 12:
                return 14

    if not values.is_empty():
        return 15

    let empty_front = values.pop_front()
    match empty_front:
        Option.none:
            return 0
        Option.some as ignored_payload:
            return 16
    return 17

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deque_wraparound_and_growth
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)

function main() -> int:
    var values = deque.Deque[int].with_capacity(4)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)

    let dropped = values.pop_front()
    match dropped:
        Option.none:
            return 1
        Option.some as payload:
            if payload.value != 10:
                return 2

    values.push_back(40)
    values.push_back(50)
    values.push_back(60)
    values.push_front(15)

    if values.len() != 6:
        return 3
    if values.capacity() < 6:
        return 4
    if read_int(values.get(0)) != 15:
        return 5
    if read_int(values.get(1)) != 20:
        return 6
    if read_int(values.get(2)) != 30:
        return 7
    if read_int(values.get(3)) != 40:
        return 8
    if read_int(values.get(4)) != 50:
        return 9
    if read_int(values.get(5)) != 60:
        return 10

    let front = values.pop_front()
    match front:
        Option.none:
            return 11
        Option.some as payload:
            if payload.value != 15:
                return 12

    let back = values.pop_back()
    match back:
        Option.none:
            return 13
        Option.some as payload:
            if payload.value != 60:
                return 14

    if read_int(values.first()) != 20:
        return 15
    if read_int(values.last()) != 50:
        return 16
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deque_with_plain_struct_elements
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque


struct Pair:
    left: int
    right: int

function main() -> int:
    var pairs = deque.Deque[Pair].create()
    defer pairs.release()
    pairs.push_back(Pair(left = 3, right = 4))
    pairs.push_front(Pair(left = 1, right = 2))

    if pairs.len() != 2:
        return 1

    let first = pairs.first()
    let last = pairs.last()
    if first == null or last == null:
        return 2

    unsafe:
        let first_pair = read(ptr[Pair]<-first)
        let last_pair = read(ptr[Pair]<-last)
        if first_pair.left != 1 or first_pair.right != 2:
            return 3
        if last_pair.left != 3 or last_pair.right != 4:
            return 4

    let removed_front = pairs.pop_front()
    match removed_front:
        Option.none:
            return 5
        Option.some as payload:
            if payload.value.left != 1 or payload.value.right != 2:
                return 6

    let removed_back = pairs.pop_back()
    match removed_back:
        Option.none:
            return 7
        Option.some as payload:
            if payload.value.left != 3 or payload.value.right != 4:
                return 8

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deque_insert_and_remove
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)

function main() -> int:
    var values = deque.Deque[int].with_capacity(6)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)
    values.push_back(40)

    let dropped = values.pop_front()
    match dropped:
        Option.none:
            return 1
        Option.some as payload:
            if payload.value != 10:
                return 2

    values.push_back(50)
    values.push_back(60)

    if not values.insert(1, 25):
        return 3
    if not values.insert(5, 55):
        return 4
    if values.insert(20, 99):
        return 5

    if values.len() != 7:
        return 6
    if read_int(values.get(0)) != 20:
        return 7
    if read_int(values.get(1)) != 25:
        return 8
    if read_int(values.get(2)) != 30:
        return 9
    if read_int(values.get(3)) != 40:
        return 10
    if read_int(values.get(4)) != 50:
        return 11
    if read_int(values.get(5)) != 55:
        return 12
    if read_int(values.get(6)) != 60:
        return 13

    let removed_front_half = values.remove(1)
    match removed_front_half:
        Option.none:
            return 14
        Option.some as payload:
            if payload.value != 25:
                return 15

    let removed_back_half = values.remove(4)
    match removed_back_half:
        Option.none:
            return 16
        Option.some as payload:
            if payload.value != 55:
                return 17

    let missing = values.remove(10)
    match missing:
        Option.none:
            return 0
        Option.some as ignored_payload:
            return 18
    return 19

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deque_rotations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)

function main() -> int:
    var values = deque.Deque[int].with_capacity(5)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)
    values.push_back(40)

    let first = values.pop_front()
    match first:
        Option.none:
            return 1
        Option.some as payload:
            if payload.value != 10:
                return 2

    values.push_back(50)
    values.push_back(60)

    values.rotate_left(7)
    if read_int(values.get(0)) != 40:
        return 3
    if read_int(values.get(1)) != 50:
        return 4
    if read_int(values.get(2)) != 60:
        return 5
    if read_int(values.get(3)) != 20:
        return 6
    if read_int(values.get(4)) != 30:
        return 7

    values.rotate_right(11)
    if read_int(values.get(0)) != 30:
        return 8
    if read_int(values.get(1)) != 40:
        return 9
    if read_int(values.get(2)) != 50:
        return 10
    if read_int(values.get(3)) != 60:
        return 11
    if read_int(values.get(4)) != 20:
        return 12

    if read_int(values.first()) != 30:
        return 13
    if read_int(values.last()) != 20:
        return 14
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deque_iter_surface
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.deque as deque

function main() -> int:
    var values = deque.Deque[int].create()
    defer values.release()
    values.push_back(10)
    values.push_back(20)
    values.push_front(5)

    var iter = values.iter()
    let first = iter.next()
    let second = iter.next()
    let third = iter.next()
    if first == null or second == null or third == null:
        return 1
    unsafe:
        if read(ptr[int]<-first) != 5 or read(ptr[int]<-second) != 10 or read(ptr[int]<-third) != 20:
            return 2
        read(ptr[int]<-second) = 12

    var total = 0
    for value in values:
        unsafe:
            total += read(value)

    if total != 37:
        return 3
    if iter.next() != null:
        return 4
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
    Dir.mktmpdir("milk-tea-std-deque") do |dir|
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
