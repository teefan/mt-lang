# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdPriorityQueueTest < Minitest::Test
  def test_host_runtime_executes_priority_queue_operations
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.maybe as maybe",
      "import std.priority_queue as priority_queue",
      "",
      "struct Key:",
      "    value: int",
      "",
      "methods Key:",
      "    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:",
      "        unsafe:",
      "            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value",
      "",
      "function dequeue_value(values: ref[priority_queue.PriorityQueue[Key]]) -> int:",
      "    let removed = values.dequeue()",
      "    match removed:",
      "        maybe.Maybe.none:",
      "            return -1",
      "        maybe.Maybe.some as payload:",
      "            return payload.value.value",
      "",
      "function main() -> int:",
      "    var values = priority_queue.PriorityQueue[Key].with_capacity(2)",
      "    defer values.release()",
      "",
      "    if values.capacity() < 2:",
      "        return 1",
      "    if not values.is_empty():",
      "        return 2",
      "    if values.peek() != null:",
      "        return 3",
      "",
      "    values.enqueue(Key(value = 4))",
      "    values.enqueue(Key(value = 1))",
      "    values.enqueue(Key(value = 6))",
      "    values.enqueue(Key(value = 2))",
      "",
      "    if values.len() != 4:",
      "        return 4",
      "    if values.capacity() < 4:",
      "        return 5",
      "",
      "    let top = values.peek()",
      "    if top == null:",
      "        return 6",
      "    unsafe:",
      "        if read(ptr[Key]<-top).value != 6:",
      "            return 7",
      "",
      "    var count = 0",
      "    var total = 0",
      "    for value in values:",
      "        unsafe:",
      "            total += read(ptr[Key]<-value).value",
      "        count += 1",
      "",
      "    if count != 4:",
      "        return 8",
      "    if total != 13:",
      "        return 9",
      "",
      "    if dequeue_value(values) != 6:",
      "        return 10",
      "    if dequeue_value(values) != 4:",
      "        return 11",
      "    if dequeue_value(values) != 2:",
      "        return 12",
      "    if dequeue_value(values) != 1:",
      "        return 13",
      "    if not values.is_empty():",
      "        return 14",
      "",
      "    values.enqueue(Key(value = 3))",
      "    values.clear()",
      "    if not values.is_empty():",
      "        return 15",
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
    Dir.mktmpdir("milk-tea-std-priority-queue") do |dir|
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
