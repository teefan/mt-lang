## Input action mapping — decouple logical actions from physical inputs.
##
## Define actions, bind keyboard/mouse/gamepad inputs, and
## query the map each frame using your platform's input API.
##
##   import std.input as inp
##   const ACTION_JUMP: ptr_uint = 0
##   var map = inp.InputMap.create()
##   map.bind_key(ACTION_JUMP, KEY_SPACE)
##   map.bind_gamepad(ACTION_JUMP, 0, GAMEPAD_BUTTON_A)
##   ...
##   if map.check_digital(ACTION_JUMP, key_down, mouse_down, gamepad_down):
##       do_jump()

import std.vec as vec


public enum InputKind: ubyte
    key = 0
    mouse_button = 1
    gamepad_button = 2


public struct InputBinding:
    kind: InputKind
    code: int
    device_id: int


public struct InputAction:
    name: str
    bindings: vec.Vec[InputBinding]


public struct InputMap:
    actions: vec.Vec[InputAction]


# ── public API ──

extending InputMap:
    public static function create() -> InputMap:
        return InputMap(actions = vec.Vec[InputAction].create())


    public editable function add_action(name: str) -> ptr_uint:
        let id = this.actions.len()
        var action = InputAction(name = name, bindings = vec.Vec[InputBinding].create())
        this.actions.push(action)
        return id


    public editable function bind_key(action_id: ptr_uint, keycode: int) -> void:
        let action_ptr = this.actions.get(action_id) else:
            return
        unsafe:
            read(action_ptr).bindings.push(
                InputBinding(kind = InputKind.key, code = keycode, device_id = 0)
            )


    public editable function bind_mouse(action_id: ptr_uint, button: int) -> void:
        let action_ptr = this.actions.get(action_id) else:
            return
        unsafe:
            read(action_ptr).bindings.push(
                InputBinding(kind = InputKind.mouse_button, code = button, device_id = 0)
            )


    public editable function bind_gamepad(action_id: ptr_uint, gamepad_id: int, button: int) -> void:
        let action_ptr = this.actions.get(action_id) else:
            return
        unsafe:
            read(action_ptr).bindings.push(
                InputBinding(kind = InputKind.gamepad_button, code = button, device_id = gamepad_id)
            )


    public function action_count() -> ptr_uint:
        return this.actions.len()


    public function action_name(action_id: ptr_uint) -> str:
        let action_ptr = this.actions.get(action_id) else:
            return ""
        unsafe:
            return read(action_ptr).name


    public function check_digital(
        action_id: ptr_uint,
        key_down: fn(code: int) -> bool,
        mouse_down: fn(button: int) -> bool,
        gamepad_down: fn(device: int, button: int) -> bool
    ) -> bool:
        let action_ptr = this.actions.get(action_id) else:
            return false
        unsafe:
            let action = read(action_ptr)
            for entry in action.bindings:
                let binding = read(entry)
                if binding.kind == InputKind.key and key_down(binding.code):
                    return true
                if binding.kind == InputKind.mouse_button and mouse_down(binding.code):
                    return true
                if binding.kind == InputKind.gamepad_button and gamepad_down(binding.device_id, binding.code):
                    return true
        return false


    public function binding_count(action_id: ptr_uint) -> ptr_uint:
        let action_ptr = this.actions.get(action_id) else:
            return 0
        unsafe:
            return read(action_ptr).bindings.len()


    public function binding_at(action_id: ptr_uint, index: ptr_uint) -> Option[InputBinding]:
        let action_ptr = this.actions.get(action_id) else:
            return Option[InputBinding].none
        unsafe:
            let b_ptr = read(action_ptr).bindings.get(index) else:
                return Option[InputBinding].none
            return Option[InputBinding].some(value = read(b_ptr))


    public editable function release() -> void:
        for entry in this.actions:
            unsafe:
                read(entry).bindings.release()
        this.actions.release()