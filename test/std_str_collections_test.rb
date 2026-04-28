# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdStrCollectionsTest < Minitest::Test
  def test_host_runtime_executes_borrowed_string_map_and_set
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_str_collections",
      "",
      "import std.str_map as str_map",
      "import std.str_set as str_set",
      "",
      "def main() -> i32:",
      "    var symbols = str_map.create[i32]()",
      "    defer str_map.release[i32](addr(symbols))",
      "    var seen = str_set.create()",
      "    defer str_set.release(addr(seen))",
      "",
      "    str_map.put[i32](addr(symbols), \"Token\", 11)",
      "    str_map.put[i32](addr(symbols), \"Parser\", 23)",
      "    str_map.put[i32](addr(symbols), \"Token\", 13)",
      "    str_set.add(addr(seen), \"module\")",
      "    str_set.add(addr(seen), \"module\")",
      "    str_set.add(addr(seen), \"import\")",
      "",
      "    var token = 0",
      "    if not str_map.get_into[i32](symbols, \"Token\", addr(token)):",
      "        return 1",
      "    if not str_set.contains(seen, \"import\"):",
      "        return 2",
      "    if not str_set.remove(addr(seen), \"module\"):",
      "        return 3",
      "    if str_set.contains(seen, \"module\"):",
      "        return 4",
      "    let total = token + cast[i32](str_map.count[i32](symbols)) + cast[i32](str_set.count(seen))",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 16, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-str-collections") do |dir|
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
