module examples.idiomatic.sdl3.rectangles

import std.sdl3 as sdl
import std.sdl3.runtime as sdl_rt

const window_width: int = 640
const window_height: int = 480
const window_title: str = "examples/renderer/rectangles"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ptr_uint = sdl.WINDOW_RESIZABLE
const rect_count: int = 16

var window: sdl.Window
var renderer: sdl.Renderer


function pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(event):
        if event.type_ == uint<-sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


function render_frame() -> void:
    let now = int<-sdl.get_ticks()
    let direction: float = if (now % 2000) >= 1000: 1.0 else: -1.0
    let scale: float = (((now % 1000) - 500) / 500.0) * direction
    let column_width: float = window_width / float<-rect_count

    var rects = zero[array[sdl.FRect, 16]]

    sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
    sdl.render_clear(renderer)

    rects[0].x = 100.0
    rects[0].y = 100.0
    rects[0].w = 100.0 + (100.0 * scale)
    rects[0].h = 100.0 + (100.0 * scale)
    sdl.set_render_draw_color(renderer, 255, 0, 0, 255)
    sdl.render_rect(renderer, rects[0])

    for index in 0..3:
        let size: float = (index + 1) * 50.0
        rects[index].w = size + (size * scale)
        rects[index].h = size + (size * scale)
        rects[index].x = (window_width - rects[index].w) / 2.0
        rects[index].y = (window_height - rects[index].h) / 2.0

    var outline_rects = array[sdl.FRect, 3](rects[0], rects[1], rects[2])
    sdl.set_render_draw_color(renderer, 0, 255, 0, 255)
    sdl.render_rects(renderer, outline_rects)

    rects[0].x = 400.0
    rects[0].y = 50.0
    rects[0].w = 100.0 + (100.0 * scale)
    rects[0].h = 50.0 + (50.0 * scale)
    sdl.set_render_draw_color(renderer, 0, 0, 255, 255)
    sdl.render_fill_rect(renderer, rects[0])

    for index in 0..rect_count:
        let height: float = index * 8.0
        rects[index].x = index * column_width
        rects[index].y = window_height - height
        rects[index].w = column_width
        rects[index].h = height

    sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
    sdl.render_fill_rects(renderer, rects)
    sdl.render_present(renderer)


function app_main() -> int:
    sdl.set_app_metadata("Example Renderer Rectangles", "1.0", "com.example.renderer-rectangles")

    if not sdl.init(sdl.INIT_VIDEO):
        return 1
    defer sdl.quit()

    if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, window, renderer):
        return 1
    defer sdl.destroy_renderer(renderer)
    defer sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(renderer, window_width, window_height, presentation_mode):
        return 1

    while pump_events():
        render_frame()

    return 0


function main(argc: int, argv: ptr[ptr[char]]) -> int:
    return sdl_rt.run_app_no_args(argc, argv, app_main)
