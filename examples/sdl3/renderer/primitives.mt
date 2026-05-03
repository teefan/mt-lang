module examples.sdl3.renderer.primitives

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/primitives"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const point_count: i32 = 500

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var points: array[c.SDL_FPoint, 500] = zero[array[c.SDL_FPoint, 500]]()


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if c.SDL_EventType.SDL_EVENT_QUIT == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    var rect = c.SDL_FRect(x = 100.0, y = 100.0, w = 440.0, h = 280.0)

    c.SDL_SetRenderDrawColor(renderer, 33, 33, 33, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderFillRect(renderer, ptr_of(ref_of(rect)))

    c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderPoints(renderer, ptr_of(ref_of(points[0])), point_count)

    c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, c.SDL_ALPHA_OPAQUE)
    rect.x += 30.0
    rect.y += 30.0
    rect.w -= 60.0
    rect.h -= 60.0
    c.SDL_RenderRect(renderer, ptr_of(ref_of(rect)))

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderLine(renderer, 0.0, 0.0, f32<-window_width, f32<-window_height)
    c.SDL_RenderLine(renderer, 0.0, f32<-window_height, f32<-window_width, 0.0)

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Primitives", c"1.0", c"com.example.renderer-primitives")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    for index in range(0, point_count):
        points[index].x = (c.SDL_randf() * 440.0) + 100.0
        points[index].y = (c.SDL_randf() * 280.0) + 100.0

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
