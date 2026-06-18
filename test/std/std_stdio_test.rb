# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdStdioTest < Minitest::Test
  def test_host_runtime_executes_stdio_formatting_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.stdio as stdio
import std.str as text_ops

function byte_at(text: str, index: ptr_uint) -> int:
    unsafe:
        return int<-ubyte<-read(text.data + index)

function main() -> int:
    var buffer = zero[array[char, 64]]
    if stdio.str_format_bounded(ptr_of(buffer[0]), 64, \"n=%d\", 7) < 0:
        return 1
    let view = text_ops.chars_as_str(ptr_of(buffer[0]))
    if not view.equal(\"n=7\"):
        return 2
    if stdio.print_format(\"ok=%d\\n\", 1) < 0:
        return 3
    return byte_at(view, 2)

    MT

    result = run_program(source, compiler:)

    assert_equal "ok=1\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 55, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdio_stream_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.stdio as stdio
import std.str as text_ops

function main() -> int:
    let writer = stdio.file_open(\"stream.txt\", \"w\")
    if writer == null:
        return 1
    if stdio.file_print(writer, \"n=%d\", 7) < 0:
        return 2
    if stdio.file_write_str(\"!\", writer) < 0:
        return 3
    if stdio.file_write_char(10, writer) == stdio.EOF:
        return 4
    if stdio.file_flush(writer) != 0:
        return 5
    if stdio.file_close(writer) != 0:
        return 6

    let reader = stdio.file_open(\"stream.txt\", \"r\")
    if reader == null:
        return 7
    var line = zero[array[char, 16]]
    if stdio.file_read_line(ptr_of(line[0]), 16, reader) == null:
        return 8
    let view = text_ops.chars_as_str(ptr_of(line[0]))
    if not view.equal(\"n=7!\\n\"):
        return 9
    if stdio.file_read_char(reader) != stdio.EOF:
        return 10
    if stdio.file_is_eof(reader) == 0:
        return 11
    if stdio.file_has_error(reader) != 0:
        return 12
    stdio.file_clear_errors(reader)
    if stdio.file_is_eof(reader) != 0:
        return 13
    return stdio.file_close(reader)

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdio_byte_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.stdio as stdio

function main() -> int:
    var source_bytes = array[ubyte, 4](1, 2, 3, 4)
    let writer = stdio.file_open(\"bytes.bin\", \"wb\")
    if writer == null:
        return 1
    if stdio.file_write_bytes(unsafe: const_ptr[void]<-ptr_of(source_bytes[0]), 1, 4, writer) != 4:
        return 2
    if stdio.file_close(writer) != 0:
        return 3

    let reader = stdio.file_open(\"bytes.bin\", \"rb\")
    if reader == null:
        return 4
    var target_bytes = zero[array[ubyte, 4]]
    if stdio.file_read_bytes(unsafe: ptr[void]<-ptr_of(target_bytes[0]), 1, 4, reader) != 4:
        return 5
    if stdio.file_close(reader) != 0:
        return 6
    return int<-target_bytes[0] + int<-target_bytes[1] + int<-target_bytes[2] + int<-target_bytes[3]

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdio_position_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.stdio as stdio

function main() -> int:
    var source_bytes = array[ubyte, 5](10, 20, 30, 40, 50)
    let writer = stdio.file_open(\"position.bin\", \"wb\")
    if writer == null:
        return 1
    if stdio.file_write_bytes(unsafe: const_ptr[void]<-ptr_of(source_bytes[0]), 1, 5, writer) != 5:
        return 2
    if stdio.file_close(writer) != 0:
        return 3

    let reader = stdio.file_open(\"position.bin\", \"rb\")
    if reader == null:
        return 4
    if stdio.file_get_pos(reader) != ptr_int<-0:
        return 5
    if stdio.file_seek(reader, ptr_int<-2, stdio.SEEK_SET) != 0:
        return 6
    if stdio.file_get_pos(reader) != ptr_int<-2:
        return 7
    var target_bytes = zero[array[ubyte, 1]]
    if stdio.file_read_bytes(unsafe: ptr[void]<-ptr_of(target_bytes[0]), 1, 1, reader) != 1:
        return 8
    if target_bytes[0] != 30:
        return 9
    if stdio.file_seek(reader, ptr_int<-1, stdio.SEEK_CUR) != 0:
        return 10
    if stdio.file_get_pos(reader) != ptr_int<-4:
        return 11
    if stdio.file_seek(reader, ptr_int<-0, stdio.SEEK_END) != 0:
        return 12
    if stdio.file_get_pos(reader) != ptr_int<-5:
        return 13
    stdio.file_rewind(reader)
    if stdio.file_get_pos(reader) != ptr_int<-0:
        return 14
    if stdio.file_read_bytes(unsafe: ptr[void]<-ptr_of(target_bytes[0]), 1, 1, reader) != 1:
        return 15
    if stdio.file_close(reader) != 0:
        return 16
    return int<-target_bytes[0]

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 10, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdio_temp_and_path_wrappers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.stdio as stdio
import std.str as text_ops

function main() -> int:
    let temp = stdio.create_temp_file()
    if temp == null:
        return 1
    if stdio.file_write_str(\"temp\", temp) < 0:
        return 2
    stdio.file_rewind(temp)
    var temp_line = zero[array[char, 8]]
    if stdio.file_read_line(ptr_of(temp_line[0]), 8, temp) == null:
        return 3
    let temp_view = text_ops.chars_as_str(ptr_of(temp_line[0]))
    if not temp_view.equal(\"temp\"):
        return 4
    if stdio.file_close(temp) != 0:
        return 5

    let writer = stdio.file_open(\"rename-source.txt\", \"w\")
    if writer == null:
        return 6
    if stdio.file_write_str(\"done\", writer) < 0:
        return 7
    if stdio.file_close(writer) != 0:
        return 8
    if stdio.file_rename(\"rename-source.txt\", \"rename-target.txt\") != 0:
        return 9

    let reader = stdio.file_open(\"rename-target.txt\", \"r\")
    if reader == null:
        return 10
    var renamed = zero[array[char, 8]]
    if stdio.file_read_line(ptr_of(renamed[0]), 8, reader) == null:
        return 11
    if stdio.file_close(reader) != 0:
        return 12
    let renamed_view = text_ops.chars_as_str(ptr_of(renamed[0]))
    if not renamed_view.equal(\"done\"):
        return 13
    if stdio.file_delete(\"rename-target.txt\") != 0:
        return 14
    if stdio.file_open(\"rename-target.txt\", \"r\") != null:
        return 15
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-stdio") do |dir|
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
