module examples.sdl3.renderer.rectangles

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/rectangles"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const rect_count: i32 = 16

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let now = i32<-c.SDL_GetTicks()
    let direction = if (now % 2000) >= 1000: 1.0 else: -1.0
    let scale = (f32<-((now % 1000) - 500) / 500.0) * direction
    let column_width = f32<-window_width / f32<-rect_count

    var rects = zero[array[c.SDL_FRect, 16]]()

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255)
    c.SDL_RenderClear(renderer)

    rects[0].x = 100.0
    rects[0].y = 100.0
    rects[0].w = 100.0 + (100.0 * scale)
    rects[0].h = 100.0 + (100.0 * scale)
    c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255)
    c.SDL_RenderRect(renderer, ptr_of(rects[0]))

    for index in 0..3:
        let size = f32<-(index + 1) * 50.0
        rects[index].w = size + (size * scale)
        rects[index].h = size + (size * scale)
        rects[index].x = (f32<-window_width - rects[index].w) / 2.0
        rects[index].y = (f32<-window_height - rects[index].h) / 2.0

    c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, 255)
    c.SDL_RenderRects(renderer, ptr_of(rects[0]), 3)

    rects[0].x = 400.0
    rects[0].y = 50.0
    rects[0].w = 100.0 + (100.0 * scale)
    rects[0].h = 50.0 + (50.0 * scale)
    c.SDL_SetRenderDrawColor(renderer, 0, 0, 255, 255)
    c.SDL_RenderFillRect(renderer, ptr_of(rects[0]))

    for index in 0..rect_count:
        let height = f32<-index * 8.0
        rects[index].x = f32<-index * column_width
        rects[index].y = f32<-window_height - height
        rects[index].w = column_width
        rects[index].h = height

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255)
    c.SDL_RenderFillRects(renderer, ptr_of(rects[0]), rect_count)
    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Rectangles", c"1.0", c"com.example.renderer-rectangles")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
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
