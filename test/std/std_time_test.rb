# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdTimeTest < Minitest::Test
  def test_host_runtime_executes_time_timestamp_and_format_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.str as text
import std.time as time

function main() -> int:
    var stored: time.Timestamp = ptr_int<-0
    let now = time.current_timestamp(stored)
    if stored != now:
        return 1
    if now <= ptr_int<-0:
        return 2

    var local_buffer = zero[array[char, 32]]
    if time.format_local_time_into(ptr_of(local_buffer[0]), 32, \"%Y\", now) != ptr_uint<-4:
        return 3
    let local_view = text.chars_as_str(ptr_of(local_buffer[0]))
    if local_view.len != ptr_uint<-4:
        return 4

    var utc_buffer = zero[array[char, 32]]
    if time.format_utc_time_into(ptr_of(utc_buffer[0]), 32, \"%m\", now) != ptr_uint<-2:
        return 5
    let utc_view = text.chars_as_str(ptr_of(utc_buffer[0]))
    if utc_view.len != ptr_uint<-2:
        return 6

    if time.format_into(ptr_of(utc_buffer[0]), 32, \"%m\", null) != ptr_uint<-0:
        return 7
    if time.seconds_between(now, stored) != 0.0:
        return 8
    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_time_clock_and_sleep_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.time as time

function main() -> int:
    var resolution = zero[time.TimeSpec]
    if time.clock_resolution_into(time.MONOTONIC_CLOCK, resolution) != 0:
        return 1
    if resolution.tv_nsec < ptr_int<-0:
        return 2

    var helper_resolution = zero[time.TimeSpec]
    if time.clock_resolution(time.MONOTONIC_CLOCK, helper_resolution) != 0:
        return 3
    var helper_now = zero[time.TimeSpec]
    if time.monotonic(helper_now) != 0:
        return 4
    var wall = zero[time.TimeSpec]
    if time.realtime(wall) != 0:
        return 5

    let one_second = time.seconds(ptr_int<-1)
    if one_second.tv_sec != ptr_int<-1 or one_second.tv_nsec != ptr_int<-0:
        return 6
    let five_ms = time.milliseconds(ptr_uint<-5)
    if five_ms.tv_sec != ptr_int<-0 or five_ms.tv_nsec != ptr_int<-5000000:
        return 7
    let precise = time.nanoseconds(ptr_uint<-1000000001)
    if precise.tv_sec != ptr_int<-1 or precise.tv_nsec != ptr_int<-1:
        return 8

    var start = zero[time.TimeSpec]
    if time.clock_time_into(time.MONOTONIC_CLOCK, start) != 0:
        return 9
    if time.sleep_milliseconds(ptr_uint<-5) != 0:
        return 10
    if time.sleep_nanoseconds(ptr_uint<-1) != 0:
        return 11
    var finish = zero[time.TimeSpec]
    if time.clock_time_into(time.MONOTONIC_CLOCK, finish) != 0:
        return 12
    if finish.tv_sec < start.tv_sec:
        return 13
    if finish.tv_sec == start.tv_sec and finish.tv_nsec < start.tv_nsec:
        return 14
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
    Dir.mktmpdir("milk-tea-std-time") do |dir|
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
