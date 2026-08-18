## Input mapping tests.
## Run via `mtc test test/mt/`.

import std.input as inp


const ACTION_JUMP: ptr_uint = 0
const ACTION_FIRE: ptr_uint = 1


function build_map() -> inp.InputMap:
    var map = inp.InputMap.create()
    let j = map.add_action("jump")
    let f = map.add_action("fire")
    map.bind_key(j, 32)
    map.bind_mouse(j, 0)
    map.bind_gamepad(j, 0, 0)
    map.bind_key(f, 17)
    return map


function always_true(_code: int) -> bool:
    return true


function always_false(_code: int) -> bool:
    return false


function gamepad_true(_device: int, _button: int) -> bool:
    return true


function gamepad_false(_device: int, _button: int) -> bool:
    return false


@[test]
function test_input_action_ids() -> void:
    var map = inp.InputMap.create()
    defer: map.release()

    let jump_id = map.add_action("jump")
    let fire_id = map.add_action("fire")
    expect(jump_id == 0, "first action is 0")
    expect(fire_id == 1, "second action is 1")
    expect(map.action_count() == 2, "two actions registered")



@[test]
function test_input_action_names() -> void:
    var map = inp.InputMap.create()
    defer: map.release()

    let _j = map.add_action("jump")
    expect(map.action_name(0) == "jump", "action name lookup")



@[test]
function test_input_binding_count() -> void:
    var map = build_map()
    defer: map.release()

    expect(map.binding_count(ACTION_JUMP) == 3, "jump has 3 bindings")
    expect(map.binding_count(ACTION_FIRE) == 1, "fire has 1 binding")



@[test]
function test_input_binding_at() -> void:
    var map = build_map()
    defer: map.release()

    let b = map.binding_at(ACTION_JUMP, 0)
    match b:
        Option.none:
            expect(false, "expected binding")
        Option.some as payload:
            expect(payload.value.kind == inp.InputKind.key, "first binding is key")
            expect(payload.value.code == 32, "key code is 32")



@[test]
function test_input_check_digital_key() -> void:
    var map = build_map()
    defer: map.release()

    let pressed = map.check_digital(ACTION_JUMP, always_true, always_false, gamepad_false)
    expect(pressed)



@[test]
function test_input_check_digital_false() -> void:
    var map = build_map()
    defer: map.release()

    let pressed = map.check_digital(ACTION_JUMP, always_false, always_false, gamepad_false)
    expect(not pressed)



@[test]
function test_input_check_digital_mouse() -> void:
    var map = build_map()
    defer: map.release()

    let pressed = map.check_digital(ACTION_JUMP, always_false, always_true, gamepad_false)
    expect(pressed)



@[test]
function test_input_check_digital_gamepad() -> void:
    var map = build_map()
    defer: map.release()

    let pressed = map.check_digital(ACTION_JUMP, always_false, always_false, gamepad_true)
    expect(pressed)



@[test]
function test_input_check_digital_bad_id() -> void:
    var map = build_map()
    defer: map.release()

    let pressed = map.check_digital(999, always_true, always_true, gamepad_true)
    expect(not pressed)



@[test]
function test_input_binding_at_out_of_range() -> void:
    var map = build_map()
    defer: map.release()

    let b = map.binding_at(ACTION_JUMP, 99)
    match b:
        Option.none:
            # expected
        Option.some:
            expect(false, "expected none for out-of-range")

