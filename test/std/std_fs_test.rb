# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdFsTest < Minitest::Test
  def test_filesystem_roundtrip_and_listing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs") do |dir|
      source = [
        "import std.fs as fs",
        "import std.maybe as maybe",
        "import std.path as path",
        "import std.status as status",
        "import std.str as text",
        "",
        "function main() -> int:",
        "    var file_path = path.join(\"#{dir}\", \"nested/example.txt\")",
        "    defer file_path.release()",
        "",
        "    let directory_path = path.dirname(file_path.as_str())",
        "    match fs.create_directories(directory_path):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        status.Status.ok:",
        "            pass",
        "",
        "    if not fs.is_directory(directory_path):",
        "        return 2",
        "",
        "    match fs.write_text(file_path.as_str(), \"hello fs\"):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 3",
        "        status.Status.ok:",
        "            pass",
        "",
        "    if not fs.exists(file_path.as_str()):",
        "        return 4",
        "    if not fs.is_file(file_path.as_str()):",
        "        return 5",
        "",
        "    match fs.read_text(file_path.as_str()):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 6",
        "        status.Status.ok as payload:",
        "            var contents = payload.value",
        "            defer contents.release()",
        "            if not contents.as_str().equal(\"hello fs\"):",
        "                return 7",
        "",
        "    match fs.canonicalize(file_path.as_str()):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 8",
        "        status.Status.ok as payload:",
        "            var canonical = payload.value",
        "            defer canonical.release()",
        "            if not canonical.as_str().ends_with(\"nested/example.txt\"):",
        "                return 9",
        "",
        "    match fs.list_entries(directory_path):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 10",
        "        status.Status.ok as payload:",
        "            var entries = payload.value",
        "            defer entries.release()",
        "            if not entries.contains(\"example.txt\"):",
        "                return 11",
        "",
        "    match fs.current_directory():",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 12",
        "        status.Status.ok as payload:",
        "            var cwd = payload.value",
        "            defer cwd.release()",
        "            if cwd.len() == 0:",
        "                return 13",
        "",
        "    return 0",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_filesystem_binary_roundtrip_rename_and_remove
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-binary") do |dir|
      source = [
        "import std.fs as fs",
        "import std.path as path",
        "import std.status as status",
        "",
        "function main() -> int:",
        "    var source_path = path.join(\"#{dir}\", \"payload.bin\")",
        "    defer source_path.release()",
        "    var renamed_path = path.join(\"#{dir}\", \"payload-renamed.bin\")",
        "    defer renamed_path.release()",
        "    var source_bytes = array[ubyte, 4](1, 2, 0, 255)",
        "",
        "    match fs.write_bytes(source_path.as_str(), unsafe: span[ubyte](data = ptr_of(source_bytes[0]), len = 4)):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        status.Status.ok:",
        "            pass",
        "",
        "    match fs.read_bytes(source_path.as_str()):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        status.Status.ok as payload:",
        "            var data = payload.value",
        "            defer data.release()",
        "            if data.len != 4:",
        "                return 3",
        "            let view = data.as_span()",
        "            unsafe:",
        "                if read(view.data + 0) != 1 or read(view.data + 1) != 2 or read(view.data + 2) != 0 or read(view.data + 3) != ubyte<-255:",
        "                    return 4",
        "",
        "    match fs.rename(source_path.as_str(), renamed_path.as_str()):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 5",
        "        status.Status.ok:",
        "            pass",
        "",
        "    if fs.exists(source_path.as_str()):",
        "        return 6",
        "    if not fs.exists(renamed_path.as_str()):",
        "        return 7",
        "",
        "    match fs.remove(renamed_path.as_str()):",
        "        status.Status.err as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 8",
        "        status.Status.ok:",
        "            pass",
        "",
        "    if fs.exists(renamed_path.as_str()):",
        "        return 9",
        "",
        "    return 0",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-fs-program") do |dir|
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
