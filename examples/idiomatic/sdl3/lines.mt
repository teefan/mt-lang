module examples.idiomatic.sdl3.lines

import std.sdl3 as sdl

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: str = "examples/renderer/lines"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: usize = sdl.WINDOW_RESIZABLE

var line_points: array[sdl.FPoint, 9] = array[sdl.FPoint, 9](
    sdl.FPoint(x = 100.0, y = 354.0),
    sdl.FPoint(x = 220.0, y = 230.0),
    sdl.FPoint(x = 140.0, y = 230.0),
    sdl.FPoint(x = 320.0, y = 100.0),
    sdl.FPoint(x = 500.0, y = 230.0),
    sdl.FPoint(x = 420.0, y = 230.0),
    sdl.FPoint(x = 540.0, y = 354.0),
    sdl.FPoint(x = 400.0, y = 354.0),
    sdl.FPoint(x = 100.0, y = 354.0),
)

var window: ptr[sdl.Window]
var renderer: ptr[sdl.Renderer]


def pump_events() -> bool:
    var event = zero[sdl.Event]()

    while sdl.poll_event(out event):
        if sdl.EventType.SDL_EVENT_QUIT == sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    sdl.set_render_draw_color(renderer, 100, 100, 100, 255)
    sdl.render_clear(renderer)

    sdl.set_render_draw_color(renderer, 127, 49, 32, 255)
    sdl.render_line(renderer, f32<-240.0, f32<-450.0, f32<-400.0, f32<-450.0)
    sdl.render_line(renderer, f32<-240.0, f32<-356.0, f32<-400.0, f32<-356.0)
    sdl.render_line(renderer, f32<-240.0, f32<-356.0, f32<-240.0, f32<-450.0)
    sdl.render_line(renderer, f32<-400.0, f32<-356.0, f32<-400.0, f32<-450.0)

    sdl.set_render_draw_color(renderer, 0, 255, 0, 255)
    sdl.render_lines(renderer, const_ptr_of(line_points[0]), 9)

    for angle in range(0, 360):
        let size: f32 = 30.0
        let x: f32 = 320.0
        let y: f32 = 95.0 - (size / 2.0)
        let radians: f32 = f32<-angle * (sdl.PI_F / 180.0)

        sdl.set_render_draw_color(
            renderer,
            u8<-sdl.rand(256),
            u8<-sdl.rand(256),
            u8<-sdl.rand(256),
            255,
        )
        sdl.render_line(renderer, x, y, x + (sdl.cosf(radians) * size), y + (sdl.sinf(radians) * size))

    sdl.render_present(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    sdl.set_app_metadata("Example Renderer Lines", "1.0", "com.example.renderer-lines")

    if not sdl.init(sdl.INIT_VIDEO):
        return 1
    defer sdl.quit()

    if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, out window, out renderer):
        return 1
    defer sdl.destroy_renderer(renderer)
    defer sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(renderer, window_width, window_height, presentation_mode):
        return 1

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return sdl.run_app(argc, argv, app_main)
