# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdFmtLogTest < Minitest::Test
  def test_host_runtime_executes_basic_formatting
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.fmt as fmt
import std.mem.arena as arena
import std.string as string

function byte_at(text: str, index: ptr_uint) -> int:
    unsafe:
        return int<-ubyte<-read(text.data + index)

function main() -> int:
    var scratch = arena.create(64)
    defer scratch.release()
    var output = string.String.create()
    defer output.release()

    fmt.append_str(ref_of(output), \"n=\")
    fmt.append_int(ref_of(output), -42)
    fmt.append_str(ref_of(output), \" ok=\")
    fmt.append_bool(ref_of(output), true)
    fmt.append_str(ref_of(output), \" size=\")
    fmt.append_ptr_uint(ref_of(output), 17)
    fmt.append_str(ref_of(output), \" u=\")
    fmt.append_uint(ref_of(output), uint<-7)
    fmt.append_str(ref_of(output), \" tail=\")
    fmt.append_cstr(ref_of(output), scratch.to_cstr(\" raw\"))

    let view = output.as_str()
    if view.len != 35:
        return 1
    let total = int<-view.len + byte_at(view, 34)
    return total

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 154, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_fmt_format_literals
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.fmt as fmt
import std.mem.arena as arena
import std.string as string

function main() -> int:
    var scratch = arena.create(64)
    defer scratch.release()
    let delta: short = -42
    let small: ubyte = 7
    let ticks: ulong = 9
    var output = fmt.format(f\"n=\#{delta} ok=\#{true} small=\#{small} ticks=\#{ticks} raw=\#{scratch.to_cstr(\"wow\")}\")
    let total = int<-output.len()
    defer output.release()
    return total

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 37, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_direct_string_sink_format_literals
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.string as string

function main() -> int:
    let value = 7
    var output = string.String.create()
    defer output.release()
    output.assign(f\"value=\#{value}\")
    output.append(f\" ok=\#{true}\")
    return int<-output.len()

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 15, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_explicit_builder_format_sinks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.fmt as fmt
import std.mem.arena as arena
import std.string as string

function main() -> int:
    var scratch = arena.create(64)
    defer scratch.release()
    let value: uint = 26
    let ratio: double = 3.5
    var output = string.String.from_str("seed")
    defer output.release()

    fmt.append_format(ref_of(output), f" hex=\#{value:x} oct=\#{value:o}")
    if output.as_str() != "seed hex=1a oct=32":
        return 1

    fmt.assign_format(ref_of(output), f"ratio=\#{ratio:.2} ok=\#{true}")
    if output.as_str() != "ratio=3.50 ok=true":
        return 2

    output.append_format(f" raw=\#{scratch.to_cstr("wow")} bin=\#{value:b}")
    if output.as_str() != "ratio=3.50 ok=true raw=wow bin=11010":
        return 3

    output.assign_format(f"HEX=\#{value:X}")
    if output.as_str() != "HEX=1A":
        return 4

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_preserves_aliasing_for_explicit_builder_format_sinks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.string as string

function main() -> int:
    var output = string.String.from_str("abc")
    defer output.release()

    output.assign_format(f"\#{output.as_str()}x")
    if output.as_str() != "abcx":
        return 1

    output.append_format(f"|\#{output.as_str()}")
    if output.as_str() != "abcx|abcx":
        return 2

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_explicit_str_buffer_format_sinks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

function main() -> int:
    let value: uint = 26
    let ratio: double = 3.5
    var buffer: str_buffer[64]

    buffer.assign_format(f"\#{value:x}")
    if buffer.as_str() != "1a":
        return 1

    buffer.append_format(f"|\#{ratio:.2}")
    if buffer.as_str() != "1a|3.50":
        return 2

    buffer.assign("abc")
    buffer.assign_format(f"\#{buffer.as_str()}x")
    if buffer.as_str() != "abcx":
        return 3

    buffer.append_format(f"|\#{buffer.as_cstr()}")
    if buffer.as_str() != "abcx|abcx":
        return 4

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

    def test_host_runtime_executes_custom_format_hooks
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

    import std.fmt as fmt
    import std.string as string

    struct Point:
        x: int
        y: int

    extending Point:
        function format_len() -> ptr_uint:
            return f"(\#{this.x}, \#{this.y})".len

        function append_format(output: ref[string.String]) -> void:
            fmt.append_format(output, f"(\#{this.x}, \#{this.y})")

    function main() -> int:
        let point = Point(x = 2, y = 3)
        let text = f"point=\#{point}"
        if text != "point=(2, 3)":
            return 1

        var output = string.String.create()
        defer output.release()
        output.append_format(f"[\#{point}]")
        if output.as_str() != "[(2, 3)]":
            return 2

        fmt.assign_format(ref_of(output), f"\#{point}!")
        if output.as_str() != "(2, 3)!":
            return 3

        var buffer: str_buffer[64]
        buffer.assign_format(f"<\#{point}>")
        if buffer.as_str() != "<(2, 3)>":
            return 4

        return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
    end

  def test_host_runtime_executes_float_format_literals
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.fmt as fmt
import std.string as string

function main() -> int:
    let ratio: float = 2.5
    let scale: double = 0.125
    var output = fmt.format(f\"ratio=\#{ratio} scale=\#{scale}\")
    defer output.release()
    return int<-output.len()

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 21, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_general_format_string_expressions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

function size(text: str) -> ptr_uint:
    return text.len

function main() -> int:
    let count = 7
    let text = f\"count=\#{count}\"
    if size(f\"ok=\#{true}\") == 0:
        return 1
    return int<-text.len

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-fmt-log") do |dir|
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
