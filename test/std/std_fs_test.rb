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

  def test_temporary_directory_root_and_temporary_file
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-tempfile") do |dir|
      source = [
        "import std.fs as fs",
        "import std.path as path",
        "import std.str as text",
        "",
        "function main() -> int:",
        "    var temp_root = fs.temporary_directory()",
        "    defer temp_root.release()",
        "    if temp_root.len() == 0:",
        "        return 1",
        "",
        "    var parent = path.join(\"#{dir}\", \"temp-root\")",
        "    defer parent.release()",
        "",
        "    match fs.create_directories(parent.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.create_temporary_file(parent.as_str(), \"milk-tea-build\", \".c\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 3",
        "        Result.success as payload:",
        "            var temp_file = payload.value",
        "            defer temp_file.release()",
        "            if not fs.is_file(temp_file.as_str()):",
        "                return 4",
        "            if path.dirname(temp_file.as_str()) != parent.as_str():",
        "                return 5",
        "            let file_name = path.basename(temp_file.as_str())",
        "            if not file_name.starts_with(\"milk-tea-build-\"):",
        "                return 6",
        "            if not file_name.ends_with(\".c\"):",
        "                return 7",
        "",
        "            match fs.write_text(temp_file.as_str(), \"int main(void) { return 0; }\"):",
        "                Result.failure as write_payload:",
        "                    var write_error = write_payload.error",
        "                    defer write_error.release()",
        "                    return 8",
        "                Result.success as ignored_write_payload:",
        "                    pass",
        "",
        "            match fs.read_text(temp_file.as_str()):",
        "                Result.failure as read_payload:",
        "                    var read_error = read_payload.error",
        "                    defer read_error.release()",
        "                    return 9",
        "                Result.success as read_payload:",
        "                    var contents = read_payload.value",
        "                    defer contents.release()",
        "                    if not contents.as_str().equal(\"int main(void) { return 0; }\"):",
        "                        return 10",
        "",
        "            match fs.remove(temp_file.as_str()):",
        "                Result.failure as remove_payload:",
        "                    var remove_error = remove_payload.error",
        "                    defer remove_error.release()",
        "                    return 11",
        "                Result.success as ignored_remove_payload:",
        "                    pass",
        "",
        "            if fs.exists(temp_file.as_str()):",
        "                return 12",
        "",
        "    match fs.create_temporary_file_in_system_temp(\"milk-tea-system\", \".txt\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 13",
        "        Result.success as payload:",
        "            var system_temp_file = payload.value",
        "            defer system_temp_file.release()",
        "            if path.dirname(system_temp_file.as_str()) != temp_root.as_str():",
        "                return 14",
        "            if not path.basename(system_temp_file.as_str()).ends_with(\".txt\"):",
        "                return 15",
        "            match fs.remove(system_temp_file.as_str()):",
        "                Result.failure as remove_payload:",
        "                    var remove_error = remove_payload.error",
        "                    defer remove_error.release()",
        "                    return 16",
        "                Result.success as ignored_remove_payload:",
        "                    pass",
        "",
        "    match fs.create_temporary_directory_in_system_temp(\"milk-tea-system-dir\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 17",
        "        Result.success as payload:",
        "            var system_temp_dir = payload.value",
        "            defer system_temp_dir.release()",
        "            if path.dirname(system_temp_dir.as_str()) != temp_root.as_str():",
        "                return 18",
        "            if not fs.is_directory(system_temp_dir.as_str()):",
        "                return 19",
        "            match fs.remove(system_temp_dir.as_str()):",
        "                Result.failure as remove_payload:",
        "                    var remove_error = remove_payload.error",
        "                    defer remove_error.release()",
        "                    return 20",
        "                Result.success as ignored_remove_payload:",
        "                    pass",
        "",
        "    return 0",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_copy_entry_and_remove_tree_for_nested_directories
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-copy-tree") do |dir|
      source = [
        "import std.fs as fs",
        "import std.path as path",
        "import std.str as text",
        "",
        "function main() -> int:",
        "    var source_root = path.join(\"#{dir}\", \"source-tree\")",
        "    defer source_root.release()",
        "    var nested_dir = path.join(source_root.as_str(), \"nested/deeper\")",
        "    defer nested_dir.release()",
        "    var root_file = path.join(source_root.as_str(), \"root.txt\")",
        "    defer root_file.release()",
        "    var deep_file = path.join(nested_dir.as_str(), \"data.txt\")",
        "    defer deep_file.release()",
        "    var target_root = path.join(\"#{dir}\", \"copied-tree\")",
        "    defer target_root.release()",
        "    var copied_file = path.join(target_root.as_str(), \"nested/deeper/data.txt\")",
        "    defer copied_file.release()",
        "",
        "    match fs.create_directories(nested_dir.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.write_text(root_file.as_str(), \"root payload\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.write_text(deep_file.as_str(), \"deep payload\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 3",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.copy_entry(source_root.as_str(), target_root.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 4",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if not fs.is_directory(target_root.as_str()):",
        "        return 5",
        "    if not fs.is_file(copied_file.as_str()):",
        "        return 6",
        "",
        "    match fs.read_text(copied_file.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 7",
        "        Result.success as payload:",
        "            var copied_contents = payload.value",
        "            defer copied_contents.release()",
        "            if not copied_contents.as_str().equal(\"deep payload\"):",
        "                return 8",
        "",
        "    match fs.remove_tree(target_root.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 9",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if fs.exists(target_root.as_str()):",
        "        return 10",
        "",
        "    match fs.remove_tree(source_root.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 11",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    if fs.exists(source_root.as_str()):",
        "        return 12",
        "",
        "    match fs.remove_tree(source_root.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 13",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    return 0",
      ].join("\n")

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
    end
  end

  def test_metadata_and_permissions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-fs-meta") do |dir|
      source = [
        "import std.fs as fs",
        "import std.path as path",
        "",
        "function main() -> int:",
        "    var file_path = path.join(\"#{dir}\", \"mode.txt\")",
        "    defer file_path.release()",
        "    var dir_path = path.join(\"#{dir}\", \"folder\")",
        "    defer dir_path.release()",
        "",
        "    match fs.create_directories(dir_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 1",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.write_text(file_path.as_str(), \"hello\"):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 2",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.metadata(file_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 3",
        "        Result.success as payload:",
        "            let info = payload.value",
        "            if not info.is_file():",
        "                return 4",
        "            if info.size != ptr_uint<-5:",
        "                return 5",
        "            if (info.mode & 511) == 0:",
        "                return 6",
        "",
        "    match fs.metadata(dir_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 7",
        "        Result.success as payload:",
        "            let info = payload.value",
        "            if not info.is_directory():",
        "                return 8",
        "",
        "    match fs.set_permissions(file_path.as_str(), 384):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 9",
        "        Result.success as ignored_payload:",
        "            pass",
        "",
        "    match fs.metadata(file_path.as_str()):",
        "        Result.failure as payload:",
        "            var error = payload.error",
        "            defer error.release()",
        "            return 10",
        "        Result.success as payload:",
        "            let info = payload.value",
        "            if (info.mode & 511) != 384:",
        "                return 11",
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
