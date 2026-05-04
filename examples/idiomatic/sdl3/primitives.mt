module examples.idiomatic.sdl3.primitives

import std.sdl3 as sdl

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: str = "examples/renderer/primitives"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: usize = sdl.WINDOW_RESIZABLE
const point_count: i32 = 500

var window: ptr[sdl.Window]
var renderer: ptr[sdl.Renderer]
var points: array[sdl.FPoint, 500] = zero[array[sdl.FPoint, 500]]


def pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(out event):
        if sdl.EventType.SDL_EVENT_QUIT == sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    var rect = sdl.FRect(x = 100.0, y = 100.0, w = 440.0, h = 280.0)

    sdl.set_render_draw_color(renderer, 33, 33, 33, 255)
    sdl.render_clear(renderer)

    sdl.set_render_draw_color(renderer, 0, 0, 255, 255)
    sdl.render_fill_rect(renderer, const_ptr_of(rect))

    sdl.set_render_draw_color(renderer, 255, 0, 0, 255)
    sdl.render_points(renderer, const_ptr_of(points[0]), point_count)

    sdl.set_render_draw_color(renderer, 0, 255, 0, 255)
    rect.x += 30.0
    rect.y += 30.0
    rect.w -= 60.0
    rect.h -= 60.0
    sdl.render_rect(renderer, const_ptr_of(rect))

    sdl.set_render_draw_color(renderer, 255, 255, 0, 255)
    sdl.render_line(renderer, f32<-0.0, f32<-0.0, f32<-window_width, f32<-window_height)
    sdl.render_line(renderer, f32<-0.0, f32<-window_height, f32<-window_width, f32<-0.0)

    sdl.render_present(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    sdl.set_app_metadata("Example Renderer Primitives", "1.0", "com.example.renderer-primitives")

    if not sdl.init(sdl.INIT_VIDEO):
        return 1
    defer sdl.quit()

    if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, out window, out renderer):
        return 1
    defer sdl.destroy_renderer(renderer)
    defer sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(renderer, window_width, window_height, presentation_mode):
        return 1

    for index in 0..point_count:
        points[index].x = (sdl.randf() * 440.0) + 100.0
        points[index].y = (sdl.randf() * 280.0) + 100.0

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return sdl.run_app(argc, argv, app_main)
