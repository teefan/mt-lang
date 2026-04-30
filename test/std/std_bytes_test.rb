# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdBytesTest < Minitest::Test
  def test_host_runtime_executes_byte_buffer_growth_and_indexing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_bytes_growth",
      "",
      "import std.bytes as bytes",
      "",
      "def main() -> i32:",
      "    var buffer = bytes.create()",
      "    defer bytes.release(addr(buffer))",
      "",
      "    bytes.push(addr(buffer), 4)",
      "    bytes.push(addr(buffer), 7)",
      "    bytes.push(addr(buffer), 9)",
      "    bytes.set(addr(buffer), 1, 6)",
      "",
      "    if bytes.count(buffer) != 3:",
      "        return 1",
      "    if bytes.capacity(buffer) < 3:",
      "        return 2",
      "",
      "    let total = cast[i32](bytes.get(buffer, 0)) + cast[i32](bytes.get(buffer, 1)) + cast[i32](bytes.get(buffer, 2))",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 19, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_byte_buffer_append_span
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_bytes_append",
      "",
      "import std.bytes as bytes",
      "",
      "def sum(values: span[u8]) -> i32:",
      "    var total = 0",
      "    var index: usize = 0",
      "    while index < values.len:",
      "        unsafe:",
      "            total += cast[i32](deref(values.data + index))",
      "        index += 1",
      "    return total",
      "",
      "def main() -> i32:",
      "    var left = bytes.with_capacity(2)",
      "    defer bytes.release(addr(left))",
      "    var right = bytes.create()",
      "    defer bytes.release(addr(right))",
      "",
      "    bytes.push(addr(left), 10)",
      "    bytes.push(addr(left), 20)",
      "    bytes.push(addr(right), 30)",
      "    bytes.append(addr(right), bytes.as_span(left))",
      "",
      "    let total = sum(bytes.as_span(right))",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 60, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-bytes") do |dir|
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
