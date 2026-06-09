# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdNetClockTest < Minitest::Test
  def test_build_and_parse_request
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.clock as clock

function main() -> int:
    let t1 = clock.monotonic_ns()
    var request = clock.build_request(t1)
    defer request.release()

    let data = request.as_span()
    let parsed = clock.parse_request(data)
    match parsed:
        Result.failure:
            return 1
        Result.success as pp:
            if pp.value != t1:
                return 2
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_build_and_parse_response
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.clock as clock

function main() -> int:
    let t1 = clock.monotonic_ns()
    let t2 = t1 + 1000000
    var response = clock.build_response(t1, t2)
    defer response.release()

    let data = response.as_span()
    let parsed = clock.parse_response(data)
    match parsed:
        Result.failure:
            return 1
        Result.success as pp:
            # offset and rtt should be reasonable
            if pp.value.rtt_us == 0:
                return 2
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_tick_clock_advance
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.clock as clock

function main() -> int:
    var tc = clock.tick_clock_new(10)
    if tc.tick != 0:
        return 1
    tc.advance()
    if tc.tick != 1:
        return 2
    tc.advance()
    tc.advance()
    if tc.tick != 3:
        return 3
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  def test_tick_clock_elapsed
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.net.clock as clock

function main() -> int:
    var tc = clock.tick_clock_new(1000)
    let elapsed = tc.elapsed_ticks()
    # With a 1000Hz clock, elapsed ticks should be >= 0
    if elapsed < 0:
        return 1
    return 0

    MT

    result = run_program(source, compiler:)
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-net-clock") do |dir|
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
