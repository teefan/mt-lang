# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdFsmTest < Minitest::Test
  def test_host_runtime_executes_table_driven_fsm
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = <<~MT

import std.fsm as fsm

enum ActorState: ubyte
    idle = 0
    walking = 1
    jumping = 2

enum ActorEvent: ubyte
    run = 0
    jump = 1
    land = 2
    stop = 3

struct Context:
    energy: int
    score: int
    updates: int

function can_jump(context: ptr[Context], input: ActorEvent, current_state: ActorState, next_state: ActorState) -> bool:
    unsafe:
        return read(context).energy >= 2

function on_transition(context: ptr[Context], input: ActorEvent, previous_state: ActorState, next_state: ActorState) -> void:
    unsafe:
        read(context).score += 10

function enter_walking(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).score += 1

function exit_walking(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).score += 2

function update_walking(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).updates += 1
        read(context).score += 3

function enter_jumping(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).energy -= 2
        read(context).score += 4

function exit_jumping(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).score += 5

function update_jumping(context: ptr[Context], state: ActorState) -> void:
    unsafe:
        read(context).updates += 10

function main() -> int:
    var machine = fsm.StateMachine[ActorState, ActorEvent, Context].create(ActorState.idle)
    defer machine.release()

    machine.add_state_hooks(
        fsm.StateHooks[ActorState, Context].create(
            ActorState.walking,
            enter_walking,
            exit_walking,
            update_walking,
        )
    )
    machine.add_state_hooks(
        fsm.StateHooks[ActorState, Context].create(
            ActorState.jumping,
            enter_jumping,
            exit_jumping,
            update_jumping,
        )
    )

    machine.add_transition(
        fsm.Transition[ActorState, ActorEvent, Context].always(
            ActorState.idle,
            ActorEvent.run,
            ActorState.walking,
            on_transition,
        )
    )
    machine.add_transition(
        fsm.Transition[ActorState, ActorEvent, Context].create(
            ActorState.walking,
            ActorEvent.jump,
            ActorState.jumping,
            can_jump,
            on_transition,
        )
    )
    machine.add_transition(
        fsm.Transition[ActorState, ActorEvent, Context].simple(
            ActorState.jumping,
            ActorEvent.land,
            ActorState.walking,
        )
    )
    machine.add_transition(
        fsm.Transition[ActorState, ActorEvent, Context].simple(
            ActorState.walking,
            ActorEvent.stop,
            ActorState.idle,
        )
    )

    if machine.transitions_len() != 4:
        return 1
    if machine.hooks_len() != 2:
        return 2
    if not machine.is_in_state(ActorState.idle):
        return 3

    var context = Context(energy = 3, score = 0, updates = 0)

    let ran = machine.dispatch(context, ActorEvent.run)
    if not ran.did_transition():
        return 4
    if ran.previous_state != ActorState.idle:
        return 5
    if ran.current_state != ActorState.walking:
        return 6

    machine.tick(context)
    if context.updates != 1:
        return 7

    let jumped = machine.dispatch(context, ActorEvent.jump)
    if not jumped.did_transition():
        return 8
    if context.energy != 1:
        return 9

    let ignored = machine.dispatch(context, ActorEvent.jump)
    if ignored.did_transition():
        return 10

    machine.tick(context)
    if context.updates != 11:
        return 11

    let landed = machine.dispatch(context, ActorEvent.land)
    if not landed.did_transition():
        return 12
    if not machine.is_in_state(ActorState.walking):
        return 13

    let stopped = machine.dispatch(context, ActorEvent.stop)
    if not stopped.did_transition():
        return 14
    if machine.state() != ActorState.idle:
        return 15

    let forced = machine.set_state(context, ActorState.jumping)
    if not forced.did_transition():
        return 16
    if context.energy != -1:
        return 17

    let same_state = machine.set_state(context, ActorState.jumping)
    if same_state.did_transition():
        return 18

    if context.score != 42:
        return context.score + 100

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
    Dir.mktmpdir("milk-tea-std-fsm") do |dir|
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
