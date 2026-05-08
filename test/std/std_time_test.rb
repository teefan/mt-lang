# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdTimeTest < Minitest::Test
  def test_host_runtime_executes_time_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_time",
      "",
      "import std.mem.arena as arena",
      "import std.status as status",
      "import std.str as text",
      "import std.string as string",
      "import std.time as time",
      "",
      "def main() -> int:",
      "    var scratch = arena.create(256)",
      "    defer scratch.release()",
      "    let formatted = time.format_utc(0, \"%Y-%m-%d\", ref_of(scratch))",
      "    if status.is_err(formatted):",
      "        match formatted:",
      "            status.Status.err as payload:",
      "                return int<-payload.error",
      "            status.Status.ok:",
      "                return 27",
      "    match formatted:",
      "        status.Status.err:",
      "            return 28",
      "        status.Status.ok as formatted_payload:",
      "            var stamp = formatted_payload.value",
      "            defer stamp.release()",
      "            let view = stamp.as_str()",
      "            if not text.equal(view, \"1970-01-01\"):",
      "                return 10",
      "            if time.now_unix_seconds() <= 0:",
      "                return 11",
      "            let epoch_clock = time.clock_utc(0)",
      "            if status.is_err(epoch_clock):",
      "                return 12",
      "            match epoch_clock:",
      "                status.Status.err:",
      "                    return 12",
      "                status.Status.ok as epoch_payload:",
      "                    let epoch_value = epoch_payload.value",
      "                    if epoch_value.hour != 0 or epoch_value.minute != 0 or epoch_value.second != 0:",
      "                        return 13",
      "            let local_clock = time.local_clock()",
      "            if status.is_err(local_clock):",
      "                return 14",
      "            match local_clock:",
      "                status.Status.err:",
      "                    return 14",
      "                status.Status.ok as local_payload:",
      "                    let local_value = local_payload.value",
      "                    if local_value.hour < 0 or local_value.hour > 23:",
      "                        return 15",
      "                    if local_value.minute < 0 or local_value.minute > 59:",
      "                        return 16",
      "                    if local_value.second < 0 or local_value.second > 59:",
      "                        return 18",
      "            if time.hour_12(time.ClockTime(hour = 0, minute = 0, second = 0)) != 12:",
      "                return 19",
      "            if time.hour_12(time.ClockTime(hour = 13, minute = 0, second = 0)) != 1:",
      "                return 20",
      "            let monotonic = time.monotonic_time()",
      "            if status.is_err(monotonic):",
      "                return 21",
      "            match monotonic:",
      "                status.Status.err:",
      "                    return 21",
      "                status.Status.ok as monotonic_payload:",
      "                    let monotonic_value = monotonic_payload.value",
      "                    if monotonic_value.tv_nsec < 0 or monotonic_value.tv_nsec >= ptr_int<-1000000000:",
      "                        return 22",
      "                    if time.timespec_to_nanoseconds(monotonic_value) < 0:",
      "                        return 23",
      "            let realtime = time.realtime_time()",
      "            if status.is_err(realtime):",
      "                return 24",
      "            match realtime:",
      "                status.Status.err:",
      "                    return 24",
      "                status.Status.ok as realtime_payload:",
      "                    let realtime_value = realtime_payload.value",
      "                    if realtime_value.tv_nsec < 0 or realtime_value.tv_nsec >= ptr_int<-1000000000:",
      "                        return 25",
      "                    if time.timespec_to_seconds(realtime_value) <= 0.0:",
      "                        return 26",
      "            let total = int<-view.len + 7",
      "            return total",
      "    return 29",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 17, result.exit_status
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
