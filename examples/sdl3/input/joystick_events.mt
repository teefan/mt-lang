module examples.sdl3.input.joystick_events

import std.c.sdl3 as c
import std.mem.heap as heap

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/input/joystick-events"
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
var ball_motion_cooldown_time: c.Uint64 = 0


def hat_state_string(state: c.Uint8) -> cstr:
    let value = u32<-state

    if value == c.SDL_HAT_CENTERED:
        return c"CENTERED"
    else:
        if value == c.SDL_HAT_UP:
            return c"UP"
        else:
            if value == c.SDL_HAT_RIGHT:
                return c"RIGHT"
            else:
                if value == c.SDL_HAT_DOWN:
                    return c"DOWN"
                else:
                    if value == c.SDL_HAT_LEFT:
                        return c"LEFT"
                    else:
                        if value == (c.SDL_HAT_RIGHT | c.SDL_HAT_UP):
                            return c"RIGHT+UP"
                        else:
                            if value == (c.SDL_HAT_RIGHT | c.SDL_HAT_DOWN):
                                return c"RIGHT+DOWN"
                            else:
                                if value == (c.SDL_HAT_LEFT | c.SDL_HAT_UP):
                                    return c"LEFT+UP"
                                else:
                                    if value == (c.SDL_HAT_LEFT | c.SDL_HAT_DOWN):
                                        return c"LEFT+DOWN"

    return c"UNKNOWN"


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
        message.str = ptr[char]<-message_text
        message.color = colors[color_index]
        message.start_ticks = c.SDL_GetTicks()
        message.next = null
        tail.next = message

    messages_tail = message


def add_plain_message(jid: u32, text: cstr) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"%s", text)

    append_message(jid, message)


def add_added_message(which: u32, joystick: ptr[c.SDL_Joystick]?) -> void:
    var message: ptr[char]? = null

    if joystick == null:
        unsafe:
            c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u add, but not opened: %s", which, c.SDL_GetError())
    else:
        unsafe:
            c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u ('%s') added", which, c.SDL_GetJoystickName(joystick))

    append_message(which, message)


def add_removed_message(which: u32) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u removed", which)

    append_message(which, message)


def add_axis_message(which: u32, axis: c.Uint8, value: c.Sint16) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u axis %d -> %d", which, i32<-axis, i32<-value)

    append_message(which, message)


def add_ball_message(which: u32, ball: c.Uint8, xrel: c.Sint16, yrel: c.Sint16) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u ball %d -> %d, %d", which, i32<-ball, i32<-xrel, i32<-yrel)

    append_message(which, message)


def add_hat_message(which: u32, hat: c.Uint8, value: c.Uint8) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u hat %d -> %s", which, i32<-hat, hat_state_string(value))

    append_message(which, message)


def add_button_message(which: u32, button: c.Uint8, down: bool) -> void:
    var message: ptr[char]? = null
    let state_text = if down: c"PRESSED" else: c"RELEASED"

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u button %d -> %s", which, i32<-button, state_text)

    append_message(which, message)


def add_battery_message(which: u32, state: c.SDL_PowerState, percent: i32) -> void:
    var message: ptr[char]? = null

    unsafe:
        c.SDL_asprintf(ptr[ptr[char]]<-ptr_of(ref_of(message)), c"Joystick #%u battery -> %s - %d%%", which, battery_state_string(state), percent)

    append_message(which, message)


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_ADDED:
                let which = event.jdevice.which
                let joystick = c.SDL_OpenJoystick(which)
                add_added_message(which, joystick)
            else:
                if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_REMOVED:
                    let which = event.jdevice.which
                    let joystick = c.SDL_GetJoystickFromID(which)
                    if joystick != null:
                        c.SDL_CloseJoystick(joystick)
                    add_removed_message(which)
                else:
                    if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_AXIS_MOTION:
                        let now = c.SDL_GetTicks()
                        if now >= axis_motion_cooldown_time:
                            axis_motion_cooldown_time = now + motion_event_cooldown
                            add_axis_message(event.jaxis.which, event.jaxis.axis, event.jaxis.value)
                    else:
                        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_BALL_MOTION:
                            let now = c.SDL_GetTicks()
                            if now >= ball_motion_cooldown_time:
                                ball_motion_cooldown_time = now + motion_event_cooldown
                                add_ball_message(event.jball.which, event.jball.ball, event.jball.xrel, event.jball.yrel)
                        else:
                            if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_HAT_MOTION:
                                add_hat_message(event.jhat.which, event.jhat.hat, event.jhat.value)
                            else:
                                if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_BUTTON_UP or event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_BUTTON_DOWN:
                                    add_button_message(event.jbutton.which, event.jbutton.button, event.jbutton.down)
                                else:
                                    if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_BATTERY_UPDATED:
                                        add_battery_message(event.jbattery.which, event.jbattery.state, event.jbattery.percent)

    return true


def render_frame() -> void:
    let now = c.SDL_GetTicks()
    var previous: ptr[EventMessage]? = ptr[EventMessage]<-ptr_of(ref_of(messages))
    var current = messages.next
    var prev_y: f32 = 0.0
    var winw: i32 = window_width
    var winh: i32 = window_height

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_GetWindowSize(window, ptr_of(ref_of(winw)), ptr_of(ref_of(winh)))

    while true:
        if current == null or previous == null:
            break

        unsafe:
            let message = ptr[EventMessage]<-current
            let previous_message = ptr[EventMessage]<-previous
            let life_percent = f32<-(now - message.start_ticks) / message_lifetime_ms

            if life_percent >= 1.0:
                let next = message.next
                previous_message.next = next

                if messages_tail == message:
                    messages_tail = previous_message

                c.SDL_free(ptr[void]<-message.str)
                heap.release(message)
                current = next
                continue

            let text_width = f32<-(c.SDL_strlen(cstr<-message.str) * usize<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
            let x = (f32<-winw - text_width) / 2.0
            let y = f32<-winh * life_percent

            if prev_y != 0.0 and (prev_y - y) < f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE:
                message.start_ticks = now
                break

            let alpha = c.Uint8<-(f32<-message.color.a * (1.0 - life_percent))
            c.SDL_SetRenderDrawColor(renderer, message.color.r, message.color.g, message.color.b, alpha)
            c.SDL_RenderDebugText(renderer, x, y, cstr<-message.str)

            prev_y = y
            previous = message
            current = message.next

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Input Joystick Events", c"1.0", c"com.example.input-joystick-events")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    messages = zero[EventMessage]()
    messages_tail = ptr[EventMessage]<-ptr_of(ref_of(messages))
    axis_motion_cooldown_time = 0
    ball_motion_cooldown_time = 0

    colors[0].r = 255
    colors[0].g = 255
    colors[0].b = 255
    colors[0].a = 255

    for index in 1..color_count:
        colors[index].r = c.Uint8<-c.SDL_rand(255)
        colors[index].g = c.Uint8<-c.SDL_rand(255)
        colors[index].b = c.Uint8<-c.SDL_rand(255)
        colors[index].a = 255

    add_plain_message(0, c"Please plug in a joystick.")

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
