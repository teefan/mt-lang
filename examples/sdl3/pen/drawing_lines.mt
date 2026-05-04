module examples.sdl3.pen.drawing_lines

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/pen/drawing-lines"

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var render_target: ptr[c.SDL_Texture]
var pressure: f32 = 0.0
var previous_touch_x: f32 = -1.0
var previous_touch_y: f32 = -1.0
var tilt_x: f32 = 0.0
var tilt_y: f32 = 0.0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_PEN_MOTION:
            if pressure > 0.0:
                if previous_touch_x >= 0.0:
                    c.SDL_SetRenderTarget(renderer, render_target)
                    c.SDL_SetRenderDrawColorFloat(renderer, 0.0, 0.0, 0.0, pressure)
                    c.SDL_RenderLine(renderer, previous_touch_x, previous_touch_y, event.pmotion.x, event.pmotion.y)

                previous_touch_x = event.pmotion.x
                previous_touch_y = event.pmotion.y
            else:
                previous_touch_x = -1.0
                previous_touch_y = -1.0
        else:
            if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_PEN_AXIS:
                if event.paxis.axis == c.SDL_PenAxis.SDL_PEN_AXIS_PRESSURE:
                    pressure = event.paxis.value
                else:
                    if event.paxis.axis == c.SDL_PenAxis.SDL_PEN_AXIS_XTILT:
                        tilt_x = event.paxis.value
                    else:
                        if event.paxis.axis == c.SDL_PenAxis.SDL_PEN_AXIS_YTILT:
                            tilt_y = event.paxis.value

    return true


def render_frame() -> void:
    var debug_text = zero[array[char, 1024]]()

    c.SDL_SetRenderTarget(renderer, null)
    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderTexture(renderer, render_target, null, null)

    unsafe:
        c.SDL_snprintf(ptr_of(debug_text[0]), 1024, c"Tilt: %f %f", tilt_x, tilt_y)
        c.SDL_RenderDebugText(renderer, 0.0, 8.0, cstr<-ptr_of(debug_text[0]))

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    var output_width: i32 = 0
    var output_height: i32 = 0

    c.SDL_SetAppMetadata(c"Example Pen Drawing Lines", c"1.0", c"com.example.pen-drawing-lines")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, 0, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_GetRenderOutputSize(renderer, ptr_of(output_width), ptr_of(output_height)):
        return 1

    let created_target = c.SDL_CreateTexture(
        renderer,
        c.SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888,
        c.SDL_TextureAccess.SDL_TEXTUREACCESS_TARGET,
        output_width,
        output_height,
    )
    if created_target == null:
        return 1

    render_target = created_target
    defer c.SDL_DestroyTexture(render_target)

    c.SDL_SetRenderTarget(renderer, render_target)
    c.SDL_SetRenderDrawColor(renderer, 100, 100, 100, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_SetRenderTarget(renderer, null)
    c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
