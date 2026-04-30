module examples.sdl3.input.gamepad_events

import std.c.sdl3 as c
import std.mem.heap as heap

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/input/gamepad-events"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const color_count: i32 = 64
const motion_event_cooldown: c.Uint64 = 40
const message_lifetime_ms: f32 = 3500.0

struct EventMessage:
    str: ptr[char]
    color: c.SDL_Color
    start_ticks: c.Uint64
    next: ptr[EventMessage]?

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var colors: array[c.SDL_Color, 64] = zero[array[c.SDL_Color, 64]]()
var messages: EventMessage = zero[EventMessage]()
var messages_tail: ptr[EventMessage]? = null
var axis_motion_cooldown_time: c.Uint64 = 0

def battery_state_string(state: c.SDL_PowerState) -> cstr:
    if state == c.SDL_PowerState.SDL_POWERSTATE_ERROR:
        return c"ERROR"
    else:
        if state == c.SDL_PowerState.SDL_POWERSTATE_UNKNOWN:
            return c"UNKNOWN"
        else:
            if state == c.SDL_PowerState.SDL_POWERSTATE_ON_BATTERY:
                return c"ON BATTERY"
            else:
                if state == c.SDL_PowerState.SDL_POWERSTATE_NO_BATTERY:
                    return c"NO BATTERY"
                else:
                    if state == c.SDL_PowerState.SDL_POWERSTATE_CHARGING:
                        return c"CHARGING"
                    else:
                        if state == c.SDL_PowerState.SDL_POWERSTATE_CHARGED:
                            return c"CHARGED"

    return c"UNKNOWN"

def append_message(jid: u32, text: ptr[char]?) -> void:
    let message_text = text
    if message_text == null:
        return

    let color_index = i32<-(jid % u32<-color_count)
    let message = heap.must_alloc_zeroed[EventMessage](1)
    let tail = messages_tail

    if tail == null:
        return

    unsafe:
        deref(message).str = ptr[char]<-message_text
        deref(message).color = colors[color_index]
        deref(message).start_ticks = c.SDL_GetTicks()
        deref(message).next = null
        deref(tail).next = message

    messages_tail = message

def add_plain_message(jid: u32, text: cstr) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(message)), c"%s", text)

    append_message(jid, message)

def add_added_message(which: u32, gamepad: ptr[c.SDL_Gamepad]?) -> void:
    var message: ptr[char]? = null

    if gamepad == null:
        unsafe:
            c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(message)), c"Gamepad #%u add, but not opened: %s", which, c.SDL_GetError())
        append_message(which, message)
        return

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(message)), c"Gamepad #%u ('%s') added", which, c.SDL_GetGamepadName(gamepad))

    append_message(which, message)

    let mapping = c.SDL_GetGamepadMapping(gamepad)
    if mapping != null:
        var mapping_message: ptr[char]? = null

        unsafe:
            c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(mapping_message)), c"Gamepad #%u mapping: %s", which, cstr<-mapping)
            c.SDL_free(ptr[void]<-(ptr[char]<-mapping))

        append_message(which, mapping_message)

def add_removed_message(which: u32) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(message)), c"Gamepad #%u removed", which)

    append_message(which, message)

def add_axis_message(which: u32, axis: c.Uint8, value: c.Sint16) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(
            ptr[ptr[char]]<-raw(addr(message)),
            c"Gamepad #%u axis %s -> %d",
            which,
            c.SDL_GetGamepadStringForAxis(c.SDL_GamepadAxis<-(i32<-axis)),
            i32<-value,
        )

    append_message(which, message)

def add_button_message(which: u32, button: c.Uint8, down: bool) -> void:
    var message: ptr[char]? = null
    let state_text = if down then c"PRESSED" else c"RELEASED"

    unsafe:
        c.SDL_asprintf(
            ptr[ptr[char]]<-raw(addr(message)),
            c"Gamepad #%u button %s -> %s",
            which,
            c.SDL_GetGamepadStringForButton(c.SDL_GamepadButton<-(i32<-button)),
            state_text,
        )

    append_message(which, message)

def add_battery_message(which: u32, state: c.SDL_PowerState, percent: i32) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-raw(addr(message)), c"Gamepad #%u battery -> %s - %d%%", which, battery_state_string(state), percent)

    append_message(which, message)

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.gdevice.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_ADDED:
                let which = event.gdevice.which
                let gamepad = c.SDL_OpenGamepad(which)
                add_added_message(which, gamepad)
            else:
                if event.gdevice.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_REMOVED:
                    let which = event.gdevice.which
                    let gamepad = c.SDL_GetGamepadFromID(which)
                    if gamepad != null:
                        c.SDL_CloseGamepad(gamepad)
                    add_removed_message(which)
                else:
                    if event.gaxis.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_AXIS_MOTION:
                        let now = c.SDL_GetTicks()
                        if now >= axis_motion_cooldown_time:
                            axis_motion_cooldown_time = now + motion_event_cooldown
                            add_axis_message(event.gaxis.which, event.gaxis.axis, event.gaxis.value)
                    else:
                        if event.gbutton.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_BUTTON_UP or event.gbutton.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                            add_button_message(event.gbutton.which, event.gbutton.button, event.gbutton.down)
                        else:
                            if event.jbattery.type == c.SDL_EventType.SDL_EVENT_JOYSTICK_BATTERY_UPDATED:
                                if c.SDL_IsGamepad(event.jbattery.which):
                                    add_battery_message(event.jbattery.which, event.jbattery.state, event.jbattery.percent)

    return true

def render_frame() -> void:
    let now = c.SDL_GetTicks()
    var previous: ptr[EventMessage]? = ptr[EventMessage]<-raw(addr(messages))
    var current = messages.next
    var prev_y: f32 = 0.0
    var winw: i32 = window_width
    var winh: i32 = window_height

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_GetWindowSize(window, raw(addr(winw)), raw(addr(winh)))

    while true:
        let message = current
        let previous_message = previous

        if message == null or previous_message == null:
            break

        unsafe:
            let life_percent = f32<-(now - deref(message).start_ticks) / message_lifetime_ms

            if life_percent >= 1.0:
                let next = deref(message).next
                deref(previous_message).next = next

                if messages_tail == message:
                    messages_tail = previous_message

                c.SDL_free(ptr[void]<-deref(message).str)
                heap.release(message)
                current = next
                continue

            let text_width = f32<-(c.SDL_strlen(cstr<-deref(message).str) * usize<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
            let x = (f32<-winw - text_width) / 2.0
            let y = f32<-winh * life_percent

            if prev_y != 0.0 and (prev_y - y) < f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE:
                deref(message).start_ticks = now
                break

            let alpha = c.Uint8<-(f32<-deref(message).color.a * (1.0 - life_percent))
            c.SDL_SetRenderDrawColor(renderer, deref(message).color.r, deref(message).color.g, deref(message).color.b, alpha)
            c.SDL_RenderDebugText(renderer, x, y, cstr<-deref(message).str)

            prev_y = y
            previous = message
            current = deref(message).next

    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Input Gamepad Events", c"1.0", c"com.example.input-gamepad-events")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    messages = zero[EventMessage]()
    messages_tail = ptr[EventMessage]<-raw(addr(messages))
    axis_motion_cooldown_time = 0

    colors[0].r = 255
    colors[0].g = 255
    colors[0].b = 255
    colors[0].a = 255

    for index in range(1, color_count):
        colors[index].r = c.Uint8<-c.SDL_rand(255)
        colors[index].g = c.Uint8<-c.SDL_rand(255)
        colors[index].b = c.Uint8<-c.SDL_rand(255)
        colors[index].a = 255

    add_plain_message(0, c"Please plug in a gamepad.")

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
