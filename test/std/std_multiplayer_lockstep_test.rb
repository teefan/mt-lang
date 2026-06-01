# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerLockstepTest < Minitest::Test
  def test_turn_collector_tracks_submission_checksums_and_desyncs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

      import std.multiplayer as mp
      import std.multiplayer.lockstep as lockstep

      function main() -> int:
          match lockstep.TurnCollector[int].create(0, 4, 7):
              Result.success as _:
                  return 1
              Result.failure as payload:
                  if payload.error.code != mp.ErrorCode.invalid_argument:
                      return 2

          var collector = lockstep.TurnCollector[int].create(2, 4, 7) else:
              return 3
          defer collector.release()

          if collector.turn_id() != 7:
              return 4
          if collector.command_count() != 0:
              return 5

          var slot0_commands = zero[array[int, 2]]
          slot0_commands[0] = 11
          slot0_commands[1] = 12
          let accepted0 = collector.submit_commands(0, 7, slot0_commands) else:
              return 6
          if accepted0 != 2:
              return 7
          if collector.seal_if_ready():
              return 8

          match collector.submit_commands(0, 7, slot0_commands):
              Result.success as _:
                  return 9
              Result.failure as payload:
                  if payload.error.code != mp.ErrorCode.already_registered:
                      return 10

          match collector.submit_commands(1, 8, slot0_commands):
              Result.success as _:
                  return 11
              Result.failure as payload:
                  if payload.error.code != mp.ErrorCode.invalid_argument:
                      return 12

          var slot1_commands = zero[array[int, 1]]
          slot1_commands[0] = 21
          let accepted1 = collector.submit_commands(1, 7, slot1_commands) else:
              return 13
          if accepted1 != 1:
              return 14
          if not collector.seal_if_ready():
              return 15

          let status0 = collector.status()
          if status0.submitted_slots != 2:
              return 16
          if status0.command_count != 3:
              return 17
          if not status0.sealed or status0.applied or status0.desynced:
              return 18

          let command0 = collector.command_at(0) else:
              return 19
          if command0.slot != 0 or command0.turn_id != 7 or command0.payload != 11:
              return 20

          let command2 = collector.command_at(2) else:
              return 21
          if command2.slot != 1 or command2.payload != 21:
              return 22

          let applied0 = collector.mark_applied(7) else:
              return 23
          if not applied0:
              return 24

          let applied_repeat = collector.mark_applied(7) else:
              return 25
          if applied_repeat:
              return 26

          let checksum0 = collector.report_checksum(0, 7, 99) else:
              return 27
          if not checksum0:
              return 28

          let checksum1 = collector.report_checksum(1, 7, 99) else:
              return 29
          if not checksum1:
              return 30

          let advanced = collector.advance_turn() else:
              return 31
          if advanced != 8:
              return 32

          let status1 = collector.status()
          if status1.turn_id != 8:
              return 33
          if status1.submitted_slots != 0 or status1.command_count != 0:
              return 34
          if status1.sealed or status1.applied or status1.desynced:
              return 35

          var mismatch0 = zero[array[int, 1]]
          mismatch0[0] = 31
          var mismatch1 = zero[array[int, 1]]
          mismatch1[0] = 41
          let queued0 = collector.submit_commands(0, 8, mismatch0) else:
              return 36
          if queued0 != 1:
              return 37

          let queued1 = collector.submit_commands(1, 8, mismatch1) else:
              return 38
          if queued1 != 1:
              return 39

          if not collector.seal_if_ready():
              return 40
          let applied1 = collector.mark_applied(8) else:
              return 41
          if not applied1:
              return 42

          let match0 = collector.report_checksum(0, 8, 123) else:
              return 43
          if not match0:
              return 44

          let match1 = collector.report_checksum(1, 8, 124) else:
              return 45
          if not match1:
              return 46

          let desync = collector.desync_report() else:
              return 47
          if desync.turn_id != 8:
              return 48
          if desync.slot != 1:
              return 49
          if desync.expected_checksum != 123 or desync.actual_checksum != 124:
              return 50

          match collector.advance_turn():
              Result.success as _:
                  return 51
              Result.failure as payload:
                  if payload.error.code != mp.ErrorCode.invalid_argument:
                      return 52

          let status2 = collector.status()
          if not status2.desynced:
              return 53
          if status2.checksum_reports != 2:
              return 54

          return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-lockstep") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.executable?(candidate) && !File.directory?(candidate)
    end
  end
end
