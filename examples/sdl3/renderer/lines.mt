module examples.sdl3.renderer.lines

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/lines"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = cast[u64](c.SDL_WINDOW_RESIZABLE)
var line_points: array[c.SDL_FPoint, 9] = array[c.SDL_FPoint, 9](
    c.SDL_FPoint(x = 100.0, y = 354.0),
    c.SDL_FPoint(x = 220.0, y = 230.0),
    c.SDL_FPoint(x = 140.0, y = 230.0),
    c.SDL_FPoint(x = 320.0, y = 100.0),
    c.SDL_FPoint(x = 500.0, y = 230.0),
    c.SDL_FPoint(x = 420.0, y = 230.0),
    c.SDL_FPoint(x = 540.0, y = 354.0),
    c.SDL_FPoint(x = 400.0, y = 354.0),
    c.SDL_FPoint(x = 100.0, y = 354.0),
)

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    c.SDL_SetRenderDrawColor(renderer, 100, 100, 100, 255)
    c.SDL_RenderClear(renderer)

    c.SDL_SetRenderDrawColor(renderer, 127, 49, 32, 255)
    c.SDL_RenderLine(renderer, 240.0, 450.0, 400.0, 450.0)
    c.SDL_RenderLine(renderer, 240.0, 356.0, 400.0, 356.0)
    c.SDL_RenderLine(renderer, 240.0, 356.0, 240.0, 450.0)
    c.SDL_RenderLine(renderer, 400.0, 356.0, 400.0, 450.0)

    c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255)
    c.SDL_RenderLines(renderer, raw(addr(line_points[0])), 9)

    for angle in range(0, 360):
        let size = 30.0
        let x = 320.0
        let y = 95.0 - (size / 2.0)
        let radians = cast[f32](angle) * (c.SDL_PI_F / 180.0)

        c.SDL_SetRenderDrawColor(
            renderer,
            cast[u8](c.SDL_rand(256)),
            cast[u8](c.SDL_rand(256)),
            cast[u8](c.SDL_rand(256)),
            255,
        )
        c.SDL_RenderLine(renderer, x, y, x + (c.SDL_cosf(radians) * size), y + (c.SDL_sinf(radians) * size))

    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Lines", c"1.0", c"com.example.renderer-lines")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
