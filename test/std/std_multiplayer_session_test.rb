# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerSessionTest < Minitest::Test
  def test_slot_roster_claim_release_and_ready_flow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer as mp

function main() -> int:
    var roster = mp.SlotRoster.create(4)
    defer roster.release()

    if roster.slot_count() != 4:
        return 1
    if roster.occupied_count() != 0:
        return 2
    if roster.open_slot_count() != 4:
        return 3
    if roster.all_occupied_ready():
        return 4

    match roster.can_start_transition(0):
        Result.success as _:
            return 5
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.invalid_argument:
                return 6

    let cannot_start_empty = roster.can_start_transition(2) else:
        return 7
    if cannot_start_empty:
        return 8

    let claimed_first = roster.claim_first_open(10) else:
        return 9
    match claimed_first:
        Option.some as payload:
            if payload.value != 0:
                return 10
        Option.none:
            return 11

    let cannot_start_short = roster.can_start_transition(2) else:
        return 12
    if cannot_start_short:
        return 13

    let claimed_specific = roster.claim_slot(11, 2) else:
        return 14
    if not claimed_specific:
        return 15

    if roster.occupied_count() != 2:
        return 16
    if roster.open_slot_count() != 2:
        return 17

    match roster.slot_for_connection(11):
        Option.some as payload:
            if payload.value != 2:
                return 18
        Option.none:
            return 19

    let repeat_same_slot = roster.claim_slot(11, 2) else:
        return 20
    if repeat_same_slot:
        return 21

    match roster.claim_first_open(10):
        Result.success as _:
            return 22
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.already_registered:
                return 23

    match roster.claim_slot(12, 9):
        Result.success as _:
            return 24
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.invalid_argument:
                return 25

    match roster.claim_slot(12, 2):
        Result.success as _:
            return 26
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.already_registered:
                return 27

    let ready_first = roster.set_ready(10, true) else:
        return 28
    if not ready_first:
        return 29

    let cannot_start_partial_ready = roster.can_start_transition(2) else:
        return 30
    if cannot_start_partial_ready:
        return 31

    match roster.begin_transition(2):
        Result.success as payload:
            match payload.value:
                Option.some:
                    return 32
                Option.none:
                    pass
        Result.failure as _:
            return 33

    let ready_repeat = roster.set_ready(10, true) else:
        return 34
    if ready_repeat:
        return 35

    let ready_second = roster.set_ready(11, true) else:
        return 36
    if not ready_second:
        return 37

    if roster.ready_count() != 2:
        return 38
    if not roster.all_occupied_ready():
        return 39

    let can_start_ready = roster.can_start_transition(2) else:
        return 40
    if not can_start_ready:
        return 41

    match roster.begin_transition(2):
        Result.success as payload:
            match payload.value:
                Option.some as participants:
                    if participants.value != 2:
                        return 42
                Option.none:
                    return 43
        Result.failure as _:
            return 44

    if roster.ready_count() != 0:
        return 45

    let cannot_restart_without_ready = roster.can_start_transition(2) else:
        return 46
    if cannot_restart_without_ready:
        return 47

    let rearm_first = roster.set_ready(10, true) else:
        return 48
    if not rearm_first:
        return 49

    let rearm_second = roster.set_ready(11, true) else:
        return 50
    if not rearm_second:
        return 51

    let can_restart_after_rearm = roster.can_start_transition(2) else:
        return 52
    if not can_restart_after_rearm:
        return 53

    match roster.begin_transition(2):
        Result.success as payload:
            match payload.value:
                Option.some as participants:
                    if participants.value != 2:
                        return 54
                Option.none:
                    return 55
        Result.failure as _:
            return 56

    if roster.ready_count() != 0:
        return 57
    if roster.occupied_count() != 2:
        return 58

    match roster.set_ready(99, true):
        Result.success as _:
            return 59
        Result.failure as payload:
            if payload.error.code != mp.ErrorCode.not_found:
                return 60

    let cleared = roster.clear_ready()
    if cleared != 0:
        return 61
    if roster.ready_count() != 0:
        return 62
    if roster.all_occupied_ready():
        return 63

    if not roster.release_connection(10):
        return 64
    if roster.release_connection(10):
        return 65
    if roster.occupied_count() != 1:
        return 66

    let reclaimed = roster.claim_slot(12, 0) else:
        return 67
    if not reclaimed:
        return 68

    match roster.slot(0):
        Option.some as payload:
            match payload.value.connection:
                Option.some as connection_payload:
                    if connection_payload.value != 12:
                        return 69
                Option.none:
                    return 70
            if payload.value.ready:
                return 71
        Option.none:
            return 72

    roster.clear()
    if roster.occupied_count() != 0:
        return 73
    if roster.ready_count() != 0:
        return 74
    if roster.open_slot_count() != 4:
        return 75

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-session") do |dir|
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
