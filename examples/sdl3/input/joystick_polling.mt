module examples.sdl3.input.joystick_polling

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/input/joystick-polling"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const color_count: i32 = 64
const joystick_size: f32 = 30.0

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var joystick: ptr[c.SDL_Joystick]? = null
var colors: array[c.SDL_Color, 64] = zero[array[c.SDL_Color, 64]]()


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_ADDED:
                if joystick == null:
                    joystick = c.SDL_OpenJoystick(event.jdevice.which)
            else:
                if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_JOYSTICK_REMOVED:
                    if joystick != null:
                        if c.SDL_GetJoystickID(joystick) == event.jdevice.which:
                            c.SDL_CloseJoystick(joystick)
                            joystick = null

    return true


def render_frame() -> void:
    var winw: i32 = window_width
    var winh: i32 = window_height
    var text: cstr = c"Plug in a joystick, please."
    var x: f32 = 0.0
    var y: f32 = 0.0

    if joystick != null:
        text = c.SDL_GetJoystickName(joystick)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_GetWindowSize(window, ptr_of(ref_of(winw)), ptr_of(ref_of(winh)))

    if joystick != null:
        var total = c.SDL_GetNumJoystickAxes(joystick)
        y = (f32<-winh - (f32<-total * joystick_size)) / 2.0
        x = f32<-winw / 2.0

        for index in 0..total:
            let color_index = index % color_count
            let value = f32<-c.SDL_GetJoystickAxis(joystick, index) / 32767.0
            let dx = x + (value * x)
            var dst = c.SDL_FRect(x = dx, y = y, w = x - c.SDL_fabsf(dx), h = joystick_size)
            c.SDL_SetRenderDrawColor(renderer, colors[color_index].r, colors[color_index].g, colors[color_index].b, colors[color_index].a)
            c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))
            y += joystick_size

        total = c.SDL_GetNumJoystickButtons(joystick)
        x = (f32<-winw - (f32<-total * joystick_size)) / 2.0

        for index in 0..total:
            let color_index = index % color_count
            var dst = c.SDL_FRect(x = x, y = 0.0, w = joystick_size, h = joystick_size)

            if c.SDL_GetJoystickButton(joystick, index):
                c.SDL_SetRenderDrawColor(renderer, colors[color_index].r, colors[color_index].g, colors[color_index].b, colors[color_index].a)
            else:
                c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)

            c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))
            c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, colors[color_index].a)
            c.SDL_RenderRect(renderer, ptr_of(ref_of(dst)))
            x += joystick_size

        total = c.SDL_GetNumJoystickHats(joystick)
        x = ((f32<-winw - (f32<-total * (joystick_size * 2.0))) / 2.0) + (joystick_size / 2.0)
        y = f32<-winh - joystick_size

        for index in 0..total:
            let color_index = index % color_count
            let third_size = joystick_size / 3.0
            let hat = u32<-c.SDL_GetJoystickHat(joystick, index)
            var cross = zero[array[c.SDL_FRect, 2]]()

            cross[0].x = x
            cross[0].y = y + third_size
            cross[0].w = joystick_size
            cross[0].h = third_size
            cross[1].x = x + third_size
            cross[1].y = y
            cross[1].w = third_size
            cross[1].h = joystick_size

            c.SDL_SetRenderDrawColor(renderer, 90, 90, 90, c.SDL_ALPHA_OPAQUE)
            c.SDL_RenderFillRects(renderer, ptr_of(ref_of(cross[0])), 2)
            c.SDL_SetRenderDrawColor(renderer, colors[color_index].r, colors[color_index].g, colors[color_index].b, colors[color_index].a)

            if (hat & c.SDL_HAT_UP) != 0:
                var dst = c.SDL_FRect(x = x + third_size, y = y, w = third_size, h = third_size)
                c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))

            if (hat & c.SDL_HAT_RIGHT) != 0:
                var dst = c.SDL_FRect(x = x + (third_size * 2.0), y = y + third_size, w = third_size, h = third_size)
                c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))

            if (hat & c.SDL_HAT_DOWN) != 0:
                var dst = c.SDL_FRect(x = x + third_size, y = y + (third_size * 2.0), w = third_size, h = third_size)
                c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))

            if (hat & c.SDL_HAT_LEFT) != 0:
                var dst = c.SDL_FRect(x = x, y = y + third_size, w = third_size, h = third_size)
                c.SDL_RenderFillRect(renderer, ptr_of(ref_of(dst)))

            x += joystick_size * 2.0

    let text_width = f32<-(c.SDL_strlen(text) * usize<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
    x = (f32<-winw - text_width) / 2.0
    y = (f32<-winh - f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE) / 2.0
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, x, y, text)
    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Input Joystick Polling", c"1.0", c"com.example.input-joystick-polling")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    for index in 0..color_count:
        colors[index].r = c.Uint8<-c.SDL_rand(255)
        colors[index].g = c.Uint8<-c.SDL_rand(255)
        colors[index].b = c.Uint8<-c.SDL_rand(255)
        colors[index].a = c.SDL_ALPHA_OPAQUE

    while pump_events():
        render_frame()

    if joystick != null:
        c.SDL_CloseJoystick(joystick)

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
