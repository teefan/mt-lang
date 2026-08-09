import std.sdl3 as sdl
import std.sdl3.runtime as runtime
import std.string as string
import std.str as text_ops
import std.vec as vec

const MOTION_EVENT_COOLDOWN: int = 40
const COLOR_COUNT: int = 64
const MSG_LIFETIME: float = 3500.0
const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


struct EventMessage:
    text: string.String
    color: sdl.Color
    start_ticks: ptr_uint


function battery_state_string(state: sdl.PowerState) -> cstr:
    return match state:
        sdl.PowerState.SDL_POWERSTATE_ERROR: c"ERROR"
        sdl.PowerState.SDL_POWERSTATE_UNKNOWN: c"UNKNOWN"
        sdl.PowerState.SDL_POWERSTATE_ON_BATTERY: c"ON BATTERY"
        sdl.PowerState.SDL_POWERSTATE_NO_BATTERY: c"NO BATTERY"
        sdl.PowerState.SDL_POWERSTATE_CHARGING: c"CHARGING"
        sdl.PowerState.SDL_POWERSTATE_CHARGED: c"CHARGED"
        _: c"UNKNOWN"


function nullable_cstr_text(text: cstr?) -> str:
    if text == null:
        return ""
    return text_ops.cstr_as_str(text)


function add_message(
    messages: ref[vec.Vec[EventMessage]],
    colors: array[sdl.Color, COLOR_COUNT],
    jid: uint,
    text: str
) -> void:
    messages.push(EventMessage(
        text = string.String.from_str(text),
        color = colors[int<-jid % COLOR_COUNT],
        start_ticks = sdl.get_ticks()
    ))


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_GAMEPAD):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/input/gamepad-events",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var colors: array[sdl.Color, COLOR_COUNT]
    colors[0] = sdl.Color(r = 255, g = 255, b = 255, a = 255)
    for i in 1..COLOR_COUNT:
        colors[i] = sdl.Color(
            r = ubyte<-sdl.rand(255),
            g = ubyte<-sdl.rand(255),
            b = ubyte<-sdl.rand(255),
            a = 255
        )

    var messages = vec.Vec[EventMessage].create()
    defer:
        let message_count = int<-messages.len()
        var index: int = 0
        while index < message_count:
            let msg = messages.get(ptr_uint<-index)
            if msg != null:
                unsafe: msg.text.release()
            index += 1
        messages.release()

    add_message(messages, colors, 0, "Please plug in a gamepad.")

    var axis_motion_cooldown_time: ptr_uint = 0

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_ADDED:
                let which = ev.gdevice.which
                let gamepad = sdl.open_gamepad(which)
                if gamepad == null:
                    add_message(messages, colors, which, f"Gamepad #{which} add, but not opened: #{sdl.get_error()}")
                else:
                    add_message(
                        messages,
                        colors,
                        which,
                        f"Gamepad #{which} ('#{nullable_cstr_text(sdl.get_gamepad_name(gamepad))}') added"
                    )
                    let mapping = sdl.get_gamepad_mapping(gamepad)
                    if mapping != null:
                        add_message(
                            messages,
                            colors,
                            which,
                            f"Gamepad #{which} mapping: #{text_ops.chars_as_str(mapping)}"
                        )
                        sdl.free(unsafe: ptr[void]<-mapping)
            else if ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_REMOVED:
                let which = ev.gdevice.which
                let gamepad = sdl.get_gamepad_from_id(which)
                if gamepad != null:
                    sdl.close_gamepad(gamepad)
                add_message(messages, colors, which, f"Gamepad #{which} removed")
            else if ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_AXIS_MOTION:
                let now = sdl.get_ticks()
                if now >= axis_motion_cooldown_time:
                    let which = ev.gaxis.which
                    axis_motion_cooldown_time = now + ptr_uint<-MOTION_EVENT_COOLDOWN
                    let axis_value = sdl.GamepadAxis<-ev.gaxis.axis
                    let axis_name = nullable_cstr_text(sdl.get_gamepad_string_for_axis(axis_value))
                    add_message(messages, colors, which, f"Gamepad #{which} axis #{axis_name} -> #{ev.gaxis.value}")
            else if (
                ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_BUTTON_UP
                or ev_type == int<-sdl.EventType.SDL_EVENT_GAMEPAD_BUTTON_DOWN
            ):
                let which = ev.gbutton.which
                let press = if ev.gbutton.down: "PRESSED" else: "RELEASED"
                let button_value = sdl.GamepadButton<-ev.gbutton.button
                let button_name = nullable_cstr_text(sdl.get_gamepad_string_for_button(button_value))
                add_message(messages, colors, which, f"Gamepad #{which} button #{button_name} -> #{press}")
            else if ev_type == int<-sdl.EventType.SDL_EVENT_JOYSTICK_BATTERY_UPDATED:
                let which = ev.jbattery.which
                if sdl.is_gamepad(which):
                    let battery_name = battery_state_string(ev.jbattery.state)
                    add_message(
                        messages,
                        colors,
                        which,
                        f"Gamepad #{which} battery -> #{battery_name} - #{ev.jbattery.percent}%"
                    )

        sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
        sdl.render_clear(renderer)
        var winw: int = 640
        var winh: int = 480
        sdl.get_window_size(window, winw, winh)

        let now = sdl.get_ticks()
        var prev_y: float = 0.0
        var i: int = 0
        while i < int<-messages.len():
            let msg = messages.at(ptr_uint<-i) else:
                break
            let life_percent = (now - msg.start_ticks) / MSG_LIFETIME
            if life_percent >= 1.0:
                let msg_ptr = messages.get(ptr_uint<-i) else:
                    break
                unsafe: msg_ptr.text.release()
                messages.remove(ptr_uint<-i)
                continue
            let text_x = (winw - runtime.debug_text_width(msg.text.as_str())) / 2.0
            let text_y = winh * life_percent
            if prev_y != 0.0 and (prev_y - text_y) < sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE:
                let msg_ptr = messages.get(ptr_uint<-i) else:
                    break
                unsafe: msg_ptr.start_ticks = now
                break
            let alpha = ubyte<-(msg.color.a * (1.0 - life_percent))
            sdl.set_render_draw_color(renderer, msg.color.r, msg.color.g, msg.color.b, alpha)
            sdl.render_debug_text(renderer, text_x, text_y, msg.text.as_str())
            prev_y = text_y
            i += 1

        sdl.render_present(renderer)

    return 0
