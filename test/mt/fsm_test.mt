# In-language tests for std.fsm (migrated from
# test/std/std_fsm_test.rb, run by `mtc test`).

import std.testing as t
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


function states_equal(left: ActorState, right: ActorState) -> bool:
    return left == right


function events_equal(left: ActorEvent, right: ActorEvent) -> bool:
    return left == right


@[test]
function test_table_driven_fsm() -> t.Check:
    var machine = fsm.StateMachine[ActorState, ActorEvent, Context].create(ActorState.idle, states_equal, events_equal)
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

    t.expect(machine.transitions_len() == 4, "4 transitions")?
    t.expect(machine.hooks_len() == 2, "2 hooks")?
    t.expect_true(machine.is_in_state(ActorState.idle))?

    var context = Context(energy = 3, score = 0, updates = 0)

    let ran = machine.dispatch(context, ActorEvent.run)
    t.expect_true(ran.did_transition())?
    t.expect(ran.previous_state == ActorState.idle, "previous state idle")?
    t.expect(ran.current_state == ActorState.walking, "current state walking")?

    machine.tick(context)
    t.expect_equal_int(context.updates, 1)?

    let jumped = machine.dispatch(context, ActorEvent.jump)
    t.expect_true(jumped.did_transition())?
    t.expect_equal_int(context.energy, 1)?

    let ignored = machine.dispatch(context, ActorEvent.jump)
    t.expect_false(ignored.did_transition())?

    machine.tick(context)
    t.expect_equal_int(context.updates, 11)?

    let landed = machine.dispatch(context, ActorEvent.land)
    t.expect_true(landed.did_transition())?
    t.expect_true(machine.is_in_state(ActorState.walking))?

    let stopped = machine.dispatch(context, ActorEvent.stop)
    t.expect_true(stopped.did_transition())?
    t.expect(machine.state() == ActorState.idle, "state is idle")?

    let forced = machine.set_state(context, ActorState.jumping)
    t.expect_true(forced.did_transition())?
    t.expect_equal_int(context.energy, -1)?

    let same_state = machine.set_state(context, ActorState.jumping)
    t.expect_false(same_state.did_transition())?

    return t.expect_equal_int(context.score, 42)
