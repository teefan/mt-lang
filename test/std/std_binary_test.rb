# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdBinaryTest < Minitest::Test
  def test_writer_round_trips_unsigned_integers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_u8(0xFF)
    w.write_u16(0xABCD)
    w.write_u32(0xDEADBEEF)
    w.write_u64(0x0123456789ABCDEF)

    var reader = bin.reader(w.as_span())

    match reader.read_u8():
        Result.failure:
            return 1
        Result.success as payload:
            if payload.value != 0xFF:
                return 2

    match reader.read_u16():
        Result.failure:
            return 3
        Result.success as payload:
            if payload.value != 0xABCD:
                return 4

    match reader.read_u32():
        Result.failure:
            return 5
        Result.success as payload:
            if payload.value != 0xDEADBEEF:
                return 6

    match reader.read_u64():
        Result.failure:
            return 7
        Result.success as payload:
            if payload.value != 0x0123456789ABCDEF:
                return 8

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_signed_integers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_i8(byte<--1)
    w.write_i16(short<--30000)
    w.write_i32(-2000000000)
    w.write_i64(-9000000000000000000)

    var reader = bin.reader(w.as_span())

    match reader.read_i8():
        Result.failure:
            return 1
        Result.success as payload:
            if payload.value != byte<--1:
                return 2

    match reader.read_i16():
        Result.failure:
            return 3
        Result.success as payload:
            if payload.value != short<--30000:
                return 4

    match reader.read_i32():
        Result.failure:
            return 5
        Result.success as payload:
            if payload.value != -2000000000:
                return 6

    match reader.read_i64():
        Result.failure:
            return 7
        Result.success as payload:
            if payload.value != -9000000000000000000:
                return 8

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_floats
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_f32(3.140000104904175)
    w.write_f64(2.718281828459045)

    var reader = bin.reader(w.as_span())

    match reader.read_f32():
        Result.failure:
            return 1
        Result.success as payload:
            if payload.value != 3.140000104904175:
                return 2

    match reader.read_f64():
        Result.failure:
            return 3
        Result.success as payload:
            if payload.value != 2.718281828459045:
                return 4

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_bool
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_bool(true)
    w.write_bool(false)
    w.write_bool(true)

    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return 1
        Result.success as payload:
            if not payload.value:
                return 2

    match reader.read_bool():
        Result.failure:
            return 3
        Result.success as payload:
            if payload.value:
                return 4

    match reader.read_bool():
        Result.failure:
            return 5
        Result.success as payload:
            if not payload.value:
                return 6

    if reader.has_more():
        return 7

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_strings
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.str as text

function main() -> int:
    var w = bin.Writer.create()
    w.write_str("hello")
    w.write_str("")
    w.write_str("world")

    var reader = bin.reader(w.as_span())

    match reader.read_str():
        Result.failure:
            return 1
        Result.success as payload:
            var s1 = payload.value
            defer s1.release()
            if not s1.as_str().equal("hello"):
                return 2

    match reader.read_str():
        Result.failure:
            return 3
        Result.success as payload:
            var s2 = payload.value
            defer s2.release()
            if s2.len() != 0:
                return 4

    match reader.read_str():
        Result.failure:
            return 5
        Result.success as payload:
            var s3 = payload.value
            defer s3.release()
            if not s3.as_str().equal("world"):
                return 6

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_bytes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.str as text

function main() -> int:
    var w = bin.Writer.create()
    let data = text.as_byte_span("abcde")
    w.write_bytes(data)

    var reader = bin.reader(w.as_span())

    match reader.read_bytes(5):
        Result.failure:
            return 1
        Result.success as payload:
            var read = payload.value
            defer read.release()
            match read.as_str():
                Option.none:
                    return 2
                Option.some as str_payload:
                    if not str_payload.value.equal("abcde"):
                        return 3

    if reader.has_more():
        return 4

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_reset_and_finish
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_u32(42)
    w.reset()
    w.write_u32(99)

    var reader = bin.reader(w.as_span())
    if w.len() != 4:
        return 1

    match reader.read_u32():
        Result.failure:
            return 2
        Result.success as payload:
            if payload.value != 99:
                return 3

    var result = w.finish()
    defer result.release()
    if result.len != 4:
        return 4

    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_write_u32_at_positional_patch
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    let header_size: ptr_uint = 4
    w.write_u32(0)

    w.write_u8(1)
    w.write_u8(2)
    w.write_u8(3)

    w.write_u32_at(0, 9999)

    var reader = bin.reader(w.as_span())

    match reader.read_u32():
        Result.failure:
            return 1
        Result.success as payload:
            if payload.value != 9999:
                return 2

    match reader.read_u8():
        Result.failure:
            return 3
        Result.success as payload:
            if payload.value != 1:
                return 4

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_reader_reports_end_of_buffer_errors
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.str as text

function main() -> int:
    var w = bin.Writer.create()
    w.write_u8(1)

    var reader = bin.reader(w.as_span())

    match reader.read_u8():
        Result.failure:
            return 1
        Result.success:
            pass

    if reader.has_more():
        return 2

    match reader.read_u8():
        Result.failure:
            return 0
        Result.success:
            return 3

    return 4

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_reader_reports_invalid_bool
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_u8(42)
    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return 0
        Result.success:
            return 1

    w.release()
    return 2

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_with_capacity_preallocates
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.with_capacity(256)
    if w.buffer.capacity() < 256:
        return 1

    if w.len() != 0:
        return 2

    w.write_u32(1)
    w.write_u32(2)
    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_reader_remaining_and_has_more
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_u32(100)
    w.write_u16(200)

    var reader = bin.reader(w.as_span())

    if reader.remaining() != 6:
        return 1

    if not reader.has_more():
        return 2

    match reader.read_u32():
        Result.failure:
            return 3
        Result.success:
            pass

    if reader.remaining() != 2:
        return 4

    match reader.read_u16():
        Result.failure:
            return 5
        Result.success:
            pass

    if reader.remaining() != 0:
        return 6

    if reader.has_more():
        return 7

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_reader_skip_advances_position
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin

function main() -> int:
    var w = bin.Writer.create()
    w.write_u32(100)
    w.write_u8(42)
    w.write_u16(200)

    var reader = bin.reader(w.as_span())

    match reader.skip(4):
        Result.failure:
            return 1
        Result.success:
            pass

    match reader.read_u8():
        Result.failure:
            return 2
        Result.success as p:
            if p.value != 42:
                return 3

    match reader.read_u16():
        Result.failure:
            return 4
        Result.success as p:
            if p.value != 200:
                return 5

    if reader.has_more():
        return 6

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_writer_round_trips_mixed_types
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.binary as bin
import std.str as text

function main() -> int:
    var w = bin.Writer.create()
    w.write_bool(true)
    w.write_u32(1234567890)
    w.write_f32(1.5)
    w.write_str("mixed")
    w.write_u16(42)

    var reader = bin.reader(w.as_span())

    match reader.read_bool():
        Result.failure:
            return 1
        Result.success as p:
            if not p.value:
                return 2

    match reader.read_u32():
        Result.failure:
            return 3
        Result.success as p:
            if p.value != 1234567890:
                return 4

    match reader.read_f32():
        Result.failure:
            return 5
        Result.success as p:
            if p.value != 1.5:
                return 6

    match reader.read_str():
        Result.failure:
            return 7
        Result.success as p:
            var s = p.value
            defer s.release()
            if not s.as_str().equal("mixed"):
                return 8

    match reader.read_u16():
        Result.failure:
            return 9
        Result.success as p:
            if p.value != 42:
                return 10

    if reader.has_more():
        return 11

    w.release()
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-binary") do |dir|
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
