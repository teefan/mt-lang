# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdPathFsTest < Minitest::Test
  def test_host_runtime_executes_path_join_and_module_relative_path
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_path",
      "",
      "import std.path as path",
      "import std.string as string",
      "",
      "def byte_at(text: str, index: usize) -> i32:",
      "    unsafe:",
      "        return cast[i32](cast[u8](deref(text.data + index)))",
      "",
      "def main() -> i32:",
      "    var joined = path.join(\"src\", \"main.mt\")",
      "    defer string.release(addr(joined))",
      "    var module_path = path.module_relative_path(\"demo.main\")",
      "    defer string.release(addr(module_path))",
      "",
      "    let joined_view = string.as_str(joined)",
      "    let module_view = string.as_str(module_path)",
      "    if joined_view.len != 11:",
      "        return 1",
      "    if module_view.len != 12:",
      "        return 2",
      "    let total = byte_at(joined_view, 3) + byte_at(module_view, 4)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 94, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_fs_write_exists_and_read_bytes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-data") do |data_dir|
      data_path = File.join(data_dir, "sample.bin")
      source = [
        "module demo.std_fs",
        "",
        "import std.bytes as bytes",
        "import std.fs as fs",
        "import std.mem.arena as arena",
        "",
        "def main() -> i32:",
        "    var scratch = arena.create(256)",
        "    defer scratch.release()",
        "    var data = bytes.create()",
        "    defer bytes.release(addr(data))",
        "",
        "    bytes.push(addr(data), 11)",
        "    bytes.push(addr(data), 22)",
        "    bytes.push(addr(data), 33)",
        "",
        "    let saved = fs.write_bytes(#{data_path.inspect}, bytes.as_span(data), addr(scratch))",
        "    if not saved.is_ok:",
        "        return cast[i32](saved.error)",
        "    if not fs.exists(#{data_path.inspect}, addr(scratch)):",
        "        return 10",
        "",
        "    let loaded = fs.read_bytes(#{data_path.inspect}, addr(scratch))",
        "    if not loaded.is_ok:",
        "        return 20 + cast[i32](loaded.error)",
        "    var loaded_data = loaded.value",
        "    defer bytes.release(addr(loaded_data))",
        "    let total = cast[i32](bytes.get(loaded_data, 0)) + cast[i32](bytes.get(loaded_data, 1)) + cast[i32](bytes.get(loaded_data, 2))",
        "    return total",
        "",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 66, result.exit_status
      assert_equal [], result.link_flags
      assert_equal [11, 22, 33].pack("C*"), File.binread(data_path)
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-path-fs") do |dir|
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
