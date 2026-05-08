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
      "function byte_at(text: str, index: ptr_uint) -> int:",
      "    unsafe:",
      "        return int<-ubyte<-read(text.data + index)",
      "",
      "function main() -> int:",
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
      "function main() -> int:",
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
      "    let total = int<-(normalized_view.len + expanded_view.len + base_view.len + dir_view.len)",
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
        "import std.status as status",
        "",
        "function main() -> int:",
        "    var data = bytes.create()",
        "    defer bytes.release(ref_of(data))",
        "",
        "    bytes.push(ref_of(data), 11)",
        "    bytes.push(ref_of(data), 22)",
        "    bytes.push(ref_of(data), 33)",
        "",
        "    let saved = fs.write_bytes(#{data_path.inspect}, bytes.as_span(data))",
        "    if status.is_err(saved):",
        "        match saved:",
        "            status.Status.err as payload:",
        "                return int<-payload.error",
        "            status.Status.ok:",
        "                return 99",
        "    if not fs.exists(#{data_path.inspect}):",
        "        return 10",
        "",
        "    let loaded = fs.read_bytes(#{data_path.inspect})",
        "    if status.is_err(loaded):",
        "        match loaded:",
        "            status.Status.err as payload:",
        "                return 20 + int<-payload.error",
        "            status.Status.ok:",
        "                return 98",
        "    match loaded:",
        "        status.Status.err:",
        "            return 97",
        "        status.Status.ok as payload:",
        "            var loaded_data = payload.value",
        "            defer bytes.release(ref_of(loaded_data))",
        "            let total = int<-bytes.get(loaded_data, 0) + int<-bytes.get(loaded_data, 1) + int<-bytes.get(loaded_data, 2)",
        "            return total",
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
        "import std.status as status",
        "import std.string as string",
        "",
        "function main() -> int:",
        "    let saved = fs.write_text(#{text_path.inspect}, \"Milk Tea\")",
        "    if status.is_err(saved):",
        "        match saved:",
        "            status.Status.err as payload:",
        "                return int<-payload.error",
        "            status.Status.ok:",
        "                return 99",
        "    let loaded = fs.read_text(#{text_path.inspect})",
        "    if status.is_err(loaded):",
        "        match loaded:",
        "            status.Status.err as payload:",
        "                return 10 + int<-payload.error",
        "            status.Status.ok:",
        "                return 98",
        "    match loaded:",
        "        status.Status.err:",
        "            return 97",
        "        status.Status.ok as payload:",
        "            var text_data = payload.value",
        "            defer text_data.release()",
        "",
        "            var invalid = bytes.create()",
        "            defer bytes.release(ref_of(invalid))",
        "            bytes.push(ref_of(invalid), ubyte<-0xC3)",
        "            bytes.push(ref_of(invalid), ubyte<-0x28)",
        "            let invalid_saved = fs.write_bytes(#{invalid_path.inspect}, bytes.as_span(invalid))",
        "            if status.is_err(invalid_saved):",
        "                match invalid_saved:",
        "                    status.Status.err as invalid_payload:",
        "                        return 20 + int<-invalid_payload.error",
        "                    status.Status.ok:",
        "                        return 96",
        "            let rejected = fs.read_text(#{invalid_path.inspect})",
        "            if status.is_ok(rejected):",
        "                match rejected:",
        "                    status.Status.ok as rejected_payload:",
        "                        var rejected_text = rejected_payload.value",
        "                        rejected_text.release()",
        "                        return 30",
        "                    status.Status.err:",
        "                        return 95",
        "",
        "            let view = text_data.as_str()",
        "            match rejected:",
        "                status.Status.ok:",
        "                    return 94",
        "                status.Status.err as rejected_payload:",
        "                    let total = int<-view.len + int<-rejected_payload.error",
        "                    return total",
        "    return 93",
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
