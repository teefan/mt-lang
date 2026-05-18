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
        "",
        "import std.path as path",
        "",
        "import std.str as text",
        "",
        "function main() -> int:",
        "    var file_path = path.join(\"#{dir}\", \"nested/example.txt\")",
        "    defer file_path.release()",
        "",
        "    let directory_path = path.dirname(file_path.as_str())",
        "    match fs.create_directories(directory_path):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if not fs.is_directory(directory_path):",
        "        return 2",
        "",
        "    match fs.write_text(file_path.as_str(), \"hello fs\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 3",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if not fs.exists(file_path.as_str()):",
        "        return 4",
        "    if not fs.is_file(file_path.as_str()):",
        "        return 5",
        "",
        "    match fs.read_text(file_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 6",
        "        Result.success as payload:",
        "            var contents = payload.value",
        "            defer contents.release()",
        "            if not contents.as_str().equal(\"hello fs\"):",
        "                return 7",
        "",
        "    match fs.canonicalize(file_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 8",
        "        Result.success as payload:",
        "            var canonical = payload.value",
        "            defer canonical.release()",
        "            if not canonical.as_str().ends_with(\"nested/example.txt\"):",
        "                return 9",
        "",
        "    match fs.list_entries(directory_path):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 10",
        "        Result.success as payload:",
        "            var entries = payload.value",
        "            defer entries.release()",
        "            if not entries.contains(\"example.txt\"):",
        "                return 11",
        "",
        "    match fs.current_directory():",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 12",
        "        Result.success as payload:",
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
        "",
        "",
        "function main() -> int:",
        "    var source_path = path.join(\"#{dir}\", \"payload.bin\")",
        "    defer source_path.release()",
        "    var renamed_path = path.join(\"#{dir}\", \"payload-renamed.bin\")",
        "    defer renamed_path.release()",
        "    var source_bytes = array[ubyte, 4](1, 2, 0, 255)",
        "",
        "    match fs.write_bytes(source_path.as_str(), unsafe: span[ubyte](data = ptr_of(source_bytes[0]), len = 4)):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.read_bytes(source_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        Result.success as payload:",
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
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 5",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if fs.exists(source_path.as_str()):",
        "        return 6",
        "    if not fs.exists(renamed_path.as_str()):",
        "        return 7",
        "",
        "    match fs.remove(renamed_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 8",
        "        Result.success as ignored_payload:",
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

  def test_create_temporary_directory_within_parent
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-tempdir") do |dir|
      source = [
        "import std.fs as fs",
        "import std.path as path",
        "import std.str as text",
        "",
        "function main() -> int:",
        "    var parent = path.join(\"#{dir}\", \"temp-root\")",
        "    defer parent.release()",
        "",
        "    match fs.create_directories(parent.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.create_temporary_directory(parent.as_str(), \"milk-tea-work\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        Result.success as payload:",
        "            var temp_dir = payload.value",
        "            defer temp_dir.release()",
        "            if not fs.is_directory(temp_dir.as_str()):",
        "                return 3",
        "            if path.dirname(temp_dir.as_str()) != parent.as_str():",
        "                return 4",
        "            if not path.basename(temp_dir.as_str()).starts_with(\"milk-tea-work-\"):",
        "                return 5",
        "",
        "            match fs.remove(temp_dir.as_str()):",
        "                Result.failure as remove_payload:",
        "                    var remove_error = remove_payload.error",
        "                    defer remove_error.release()",
        "                    return 6",
        "                Result.success as ignored_remove_payload:",
        "                    pass",
        "",
        "            if fs.exists(temp_dir.as_str()):",
        "                return 7",
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
