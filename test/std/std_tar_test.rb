# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdTarTest < Minitest::Test
  def test_host_runtime_archives_and_extracts_tar_gzip_trees
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-tar") do |dir|
      source = <<~MT

import std.fs as fs
import std.path as path
import std.tar as tar
import std.str as text

function main() -> int:
    var source_root = path.join(\"#{dir}\", \"source\")
    defer source_root.release()
    var nested_dir = path.join(source_root.as_str(), \"nested\")
    defer nested_dir.release()
    var root_file = path.join(source_root.as_str(), \"root.txt\")
    defer root_file.release()
    var tool_file = path.join(nested_dir.as_str(), \"tool.sh\")
    defer tool_file.release()
    var hidden_file = path.join(source_root.as_str(), \".secret\")
    defer hidden_file.release()
    var extract_root = path.join(\"#{dir}\", \"extract\")
    defer extract_root.release()
    var extract_bundle = path.join(extract_root.as_str(), \"bundle\")
    defer extract_bundle.release()
    var extracted_tool = path.join(extract_bundle.as_str(), \"nested/tool.sh\")
    defer extracted_tool.release()
    var extracted_hidden = path.join(extract_bundle.as_str(), \".secret\")
    defer extracted_hidden.release()
    var extract_root_with_hidden = path.join(\"#{dir}\", \"extract-with-hidden\")
    defer extract_root_with_hidden.release()
    var extracted_hidden_copy = path.join(extract_root_with_hidden.as_str(), \".secret\")
    defer extracted_hidden_copy.release()

    match fs.create_directories(nested_dir.as_str()):
        Result.failure as create_dir_error_payload:
            var error = create_dir_error_payload.error
            defer error.release()
            return 1
        Result.success as ignored_payload:
            pass

    match fs.write_text(root_file.as_str(), \"root payload\"):
        Result.failure as root_write_error_payload:
            var error = root_write_error_payload.error
            defer error.release()
            return 2
        Result.success as ignored_payload:
            pass

    match fs.write_text(tool_file.as_str(), \"#!/bin/sh\\necho tar\\n\"):
        Result.failure as tool_write_error_payload:
            var error = tool_write_error_payload.error
            defer error.release()
            return 3
        Result.success as ignored_payload:
            pass

    match fs.write_text(hidden_file.as_str(), \"hidden payload\"):
        Result.failure as hidden_write_error_payload:
            var error = hidden_write_error_payload.error
            defer error.release()
            return 4
        Result.success as ignored_payload:
            pass

    match fs.set_permissions(tool_file.as_str(), 448):
        Result.failure as permission_error_payload:
            var error = permission_error_payload.error
            defer error.release()
            return 5
        Result.success as ignored_payload:
            pass

    match tar.archive_directory_gzip(source_root.as_str(), \"bundle\", false):
        Result.failure as first_archive_error_payload:
            var error = first_archive_error_payload.error
            defer error.release()
            return 6
        Result.success as first_archive_payload:
            var archive = first_archive_payload.value
            defer archive.release()
            if archive.len == 0:
                return 7

            match tar.extract_gzip(archive.as_span(), extract_root.as_str()):
                Result.failure as first_extract_error_payload:
                    var error = first_extract_error_payload.error
                    defer error.release()
                    return 8
                Result.success as ignored_payload:
                    pass

    if not fs.is_directory(extract_bundle.as_str()):
        return 9
    if not fs.is_file(extracted_tool.as_str()):
        return 10
    if fs.exists(extracted_hidden.as_str()):
        return 11

    match fs.read_text(extracted_tool.as_str()):
        Result.failure as tool_read_error_payload:
            var error = tool_read_error_payload.error
            defer error.release()
            return 12
        Result.success as tool_read_payload:
            var contents = tool_read_payload.value
            defer contents.release()
            if not contents.as_str().equal(\"#!/bin/sh\\necho tar\\n\"):
                return 13

    match fs.metadata(extracted_tool.as_str()):
        Result.failure as metadata_error_payload:
            var error = metadata_error_payload.error
            defer error.release()
            return 14
        Result.success as metadata_payload:
            let info = metadata_payload.value
            if (info.mode & 511) != 448:
                return 15

    match tar.archive_directory_gzip(source_root.as_str(), \"\", true):
        Result.failure as second_archive_error_payload:
            var error = second_archive_error_payload.error
            defer error.release()
            return 16
        Result.success as second_archive_payload:
            var archive = second_archive_payload.value
            defer archive.release()
            match tar.extract_gzip(archive.as_span(), extract_root_with_hidden.as_str()):
                Result.failure as second_extract_error_payload:
                    var error = second_extract_error_payload.error
                    defer error.release()
                    return 17
                Result.success as ignored_payload:
                    pass

    if not fs.is_file(extracted_hidden_copy.as_str()):
        return 18

    match fs.read_text(extracted_hidden_copy.as_str()):
        Result.failure as hidden_read_error_payload:
            var error = hidden_read_error_payload.error
            defer error.release()
            return 19
        Result.success as hidden_read_payload:
            var contents = hidden_read_payload.value
            defer contents.release()
            if not contents.as_str().equal(\"hidden payload\"):
                return 20

    return 0
      MT

      result = run_program(source, compiler:)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_includes result.link_flags, "-lz"
    end
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-tar-program") do |dir|
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
