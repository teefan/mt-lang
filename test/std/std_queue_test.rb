# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdQueueTest < Minitest::Test
  def test_host_runtime_executes_queue_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.maybe as maybe",
      "import std.queue as queue",
      "",
      "function dequeue_value(values: ref[queue.Queue[int]]) -> int:",
      "    let removed = values.dequeue()",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return -1",
      "        maybe.Maybe.some as payload:",
      "            return payload.value",
      "",
      "function main() -> int:",
      "    var values = queue.Queue[int].with_capacity(2)",
      "    defer values.release()",
      "",
      "    if values.capacity() < 2:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.peek() != null:",
      "        return 3",
      "",
      "    values.enqueue(10)",
      "    values.enqueue(20)",
      "    values.enqueue(30)",
      "",
      "    if values.len() != 3:",
      "        return 4",
      "",
      "    let front = values.peek()",
      "    if front == null:",
      "        return 5",
      "    unsafe:",
      "        read(ptr[int]<-front) = 12",
      "",
      "    var total = 0",
      "    var count = 0",
      "    for value in values:",
      "        unsafe:",
      "            total += read(value)",
      "        count += 1",
      "    if count != 3:",
      "        return 6",
      "    if total != 62:",
      "        return 7",
      "",
      "    if dequeue_value(values) != 12:",
      "        return 8",
      "    if dequeue_value(values) != 20:",
      "        return 9",
      "    if dequeue_value(values) != 30:",
      "        return 10",
      "    if not values.is_empty():",
      "        return 11",
      "",
      "    values.enqueue(4)",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 12",
      "    if values.peek() != null:",
      "        return 13",
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
    Dir.mktmpdir("milk-tea-std-queue") do |dir|
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
