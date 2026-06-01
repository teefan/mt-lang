# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMultiplayerRollbackTest < Minitest::Test
  def test_rollback_history_supports_record_lookup_and_trim_boundaries
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer.rollback as rollback
import std.multiplayer.protocol as protocol

struct PlayerState:
    hp: int

function apply_input(state: PlayerState, input: int) -> PlayerState:
    return PlayerState(hp = state.hp + input)

function main() -> int:
    var inputs = rollback.History[int].create(3)
    defer inputs.release()

    if inputs.max_frames() != 3:
        return 1
    if not inputs.is_empty():
        return 2

    let appended0 = inputs.record(10, 1) else:
        return 3
    if not appended0:
        return 4

    let appended1 = inputs.record(11, 2) else:
        return 5
    if not appended1:
        return 6

    let replaced = inputs.record(11, 3) else:
        return 7
    if replaced:
        return 8

    let latest0 = inputs.latest() else:
        return 9
    if latest0.tick != 11 or latest0.value != 3:
        return 10

    match inputs.record(10, 9):
        Result.success as _:
            return 11
        Result.failure as payload:
            if payload.error.code != protocol.ErrorCode.invalid_argument:
                return 12

    let appended2 = inputs.record(12, 4) else:
        return 13
    if not appended2:
        return 14

    let appended3 = inputs.record(13, 5) else:
        return 15
    if not appended3:
        return 16

    if inputs.len() != 3:
        return 17

    let oldest = inputs.oldest() else:
        return 18
    if oldest.tick != 11 or oldest.value != 3:
        return 19

    let latest1 = inputs.latest() else:
        return 20
    if latest1.tick != 13 or latest1.value != 5:
        return 21

    let found = inputs.find(12) else:
        return 22
    if found.value != 4:
        return 23

    let removed_after = inputs.discard_after(11)
    if removed_after != 2:
        return 24
    if inputs.len() != 1:
        return 25

    let appended4 = inputs.record(12, 8) else:
        return 26
    if not appended4:
        return 27

    let appended5 = inputs.record(13, 9) else:
        return 28
    if not appended5:
        return 29

    let removed_before = inputs.discard_before(12)
    if removed_before != 1:
        return 30

    let oldest_after = inputs.oldest() else:
        return 31
    if oldest_after.tick != 12 or oldest_after.value != 8:
        return 32

    var states = rollback.History[PlayerState].create(2)
    defer states.release()

    let state0 = states.record(20, PlayerState(hp = 40)) else:
        return 33
    if not state0:
        return 34

    let state1 = states.record(21, PlayerState(hp = 55)) else:
        return 35
    if not state1:
        return 36

    let state2 = states.record(22, PlayerState(hp = 70)) else:
        return 37
    if not state2:
        return 38

    if states.len() != 2:
        return 39

    let latest_state = states.latest() else:
        return 40
    if latest_state.tick != 22 or latest_state.value.hp != 70:
        return 41

    let oldest_state = states.oldest() else:
        return 42
    if oldest_state.tick != 21 or oldest_state.value.hp != 55:
        return 43

    var predicted_states = rollback.History[PlayerState].create(6)
    defer predicted_states.release()
    var replay_inputs = rollback.History[int].create(6)
    defer replay_inputs.release()

    let base0 = predicted_states.record(100, PlayerState(hp = 10)) else:
        return 44
    if not base0:
        return 45

    let base1 = predicted_states.record(101, PlayerState(hp = 16)) else:
        return 46
    if not base1:
        return 47

    let predicted0 = predicted_states.record(102, PlayerState(hp = 999)) else:
        return 48
    if not predicted0:
        return 49

    let predicted1 = predicted_states.record(103, PlayerState(hp = 999)) else:
        return 50
    if not predicted1:
        return 51

    let input0 = replay_inputs.record(102, 7) else:
        return 52
    if not input0:
        return 53

    let input1 = replay_inputs.record(103, 9) else:
        return 54
    if not input1:
        return 55

    let replayed = rollback.resimulate_from(ref_of(predicted_states), ref_of(replay_inputs), 101, apply_input) else:
        return 56
    if replayed != 2:
        return 57

    let replayed_102 = predicted_states.find(102) else:
        return 58
    if replayed_102.value.hp != 23:
        return 59

    let replayed_103 = predicted_states.find(103) else:
        return 60
    if replayed_103.value.hp != 32:
        return 61

    match rollback.resimulate_from(ref_of(predicted_states), ref_of(replay_inputs), 99, apply_input):
        Result.success as _:
            return 62
        Result.failure as payload:
            if payload.error.code != protocol.ErrorCode.invalid_argument:
                return 63

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_resimulate_from_supports_authoritative_player_correction_flow
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.multiplayer.rollback as rollback

type PlayerPosition = int
type MoveInput = int

function apply_move(state: PlayerPosition, input: MoveInput) -> PlayerPosition:
    return state + input

function main() -> int:
    var state_history = rollback.History[PlayerPosition].create(8)
    defer state_history.release()
    var input_history = rollback.History[MoveInput].create(8)
    defer input_history.release()

    let state0 = state_history.record(200, 10) else:
        return 1
    if not state0:
        return 2

    let state1 = state_history.record(201, 14) else:
        return 3
    if not state1:
        return 4

    let predicted0 = state_history.record(202, 999) else:
        return 5
    if not predicted0:
        return 6

    let predicted1 = state_history.record(203, 999) else:
        return 7
    if not predicted1:
        return 8

    let input0 = input_history.record(202, 6) else:
        return 9
    if not input0:
        return 10

    let input1 = input_history.record(203, -2) else:
        return 11
    if not input1:
        return 12

    let trimmed = state_history.discard_after(201)
    if trimmed != 2:
        return 13

    let rewritten = state_history.record(201, 20) else:
        return 14
    if rewritten:
        return 15

    let replayed = rollback.resimulate_from(ref_of(state_history), ref_of(input_history), 201, apply_move) else:
        return 16
    if replayed != 2:
        return 17

    let corrected_202 = state_history.find(202) else:
        return 18
    if corrected_202.value != 26:
        return 19

    let corrected_203 = state_history.find(203) else:
        return 20
    if corrected_203.value != 24:
        return 21

    if state_history.len() != 4:
        return 22

    return 0

    MT

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-multiplayer-rollback") do |dir|
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
