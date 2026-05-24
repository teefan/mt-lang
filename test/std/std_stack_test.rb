# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdStackTest < Minitest::Test
  def test_host_runtime_executes_stack_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT


import std.stack as stack

function pop_value(values: ref[stack.Stack[int]]) -> int:
    let removed = values.pop()
    match removed:
        Option.none:
            return -1
        Option.some as payload:
            return payload.value

function main() -> int:
    var values = stack.Stack[int].with_capacity(2)
    defer values.release()

    if values.capacity() < 2:
        return 1
    if not values.is_empty():
        return 2
    if values.peek() != null:
        return 3

    values.push(10)
    values.push(20)
    values.push(30)

    if values.len() != 3:
        return 4

    let top = values.peek()
    if top == null:
        return 5
    unsafe:
        read(ptr[int]<-top) = 32

    var total = 0
    var count = 0
    for value in values:
        unsafe:
            total += read(value)
        count += 1
    if count != 3:
        return 6
    if total != 62:
        return 7

    if pop_value(values) != 32:
        return 8
    if pop_value(values) != 20:
        return 9
    if pop_value(values) != 10:
        return 10
    if not values.is_empty():
        return 11

    values.push(4)
    values.clear()
    if not values.is_empty():
        return 12
    if values.peek() != null:
        return 13
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
    Dir.mktmpdir("milk-tea-std-stack") do |dir|
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
