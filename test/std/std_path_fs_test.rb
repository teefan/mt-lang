# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

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
      "    defer joined.release()",
      "    var module_path = path.module_relative_path(\"demo.main\")",
      "    defer module_path.release()",
      "",
      "    let joined_view = joined.as_str()",
      "    let module_view = module_path.as_str()",
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

  def test_host_runtime_executes_path_normalize_expand_and_names
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_path_expand",
      "",
      "import std.path as path",
      "import std.string as string",
      "",
      "def main() -> i32:",
      "    var normalized = path.normalize(\"/a//b/../c/.\")",
      "    defer normalized.release()",
      "    var expanded = path.expand(\"src/../main.mt\", \"/work/project\")",
      "    defer expanded.release()",
      "    var base = path.basename(\"/tmp/demo/main.mt\")",
      "    defer base.release()",
      "    var dir = path.dirname(\"/tmp/demo/main.mt\")",
      "    defer dir.release()",
      "",
      "    let normalized_view = normalized.as_str()",
      "    let expanded_view = expanded.as_str()",
      "    let base_view = base.as_str()",
      "    let dir_view = dir.as_str()",
      "    let total = cast[i32](normalized_view.len + expanded_view.len + base_view.len + dir_view.len)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 41, result.exit_status
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

  def test_host_runtime_executes_fs_write_and_read_text_with_utf8_validation
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-text") do |data_dir|
      text_path = File.join(data_dir, "sample.txt")
      invalid_path = File.join(data_dir, "invalid.txt")
      source = [
        "module demo.std_fs_text",
        "",
        "import std.bytes as bytes",
        "import std.fs as fs",
        "import std.mem.arena as arena",
        "import std.string as string",
        "",
        "def main() -> i32:",
        "    var scratch = arena.create(256)",
        "    defer scratch.release()",
        "",
        "    let saved = fs.write_text(#{text_path.inspect}, \"Milk Tea\", addr(scratch))",
        "    if not saved.is_ok:",
        "        return cast[i32](saved.error)",
        "    let loaded = fs.read_text(#{text_path.inspect}, addr(scratch))",
        "    if not loaded.is_ok:",
        "        return 10 + cast[i32](loaded.error)",
        "    var text_data = loaded.value",
        "    defer text_data.release()",
        "",
        "    var invalid = bytes.create()",
        "    defer bytes.release(addr(invalid))",
        "    bytes.push(addr(invalid), cast[u8](0xC3))",
        "    bytes.push(addr(invalid), cast[u8](0x28))",
        "    let invalid_saved = fs.write_bytes(#{invalid_path.inspect}, bytes.as_span(invalid), addr(scratch))",
        "    if not invalid_saved.is_ok:",
        "        return 20 + cast[i32](invalid_saved.error)",
        "    let rejected = fs.read_text(#{invalid_path.inspect}, addr(scratch))",
        "    if rejected.is_ok:",
        "        var rejected_text = rejected.value",
        "        rejected_text.release()",
        "        return 30",
        "",
        "    let view = text_data.as_str()",
        "    let total = cast[i32](view.len) + cast[i32](rejected.error)",
        "    return total",
        "",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 13, result.exit_status
      assert_equal [], result.link_flags
      assert_equal "Milk Tea", File.read(text_path)
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
