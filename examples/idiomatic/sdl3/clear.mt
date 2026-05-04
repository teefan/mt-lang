module examples.idiomatic.sdl3.clear

import std.sdl3 as sdl

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: str = "examples/renderer/clear"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: usize = sdl.WINDOW_RESIZABLE

var window: ptr[sdl.Window]
var renderer: ptr[sdl.Renderer]


def pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(out event):
        if sdl.EventType.SDL_EVENT_QUIT == sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let seconds = f32<-sdl.get_ticks() / 1000.0
    let red = (sdl.sinf(seconds) * 0.5) + 0.5
    let green = (sdl.sinf(seconds + (sdl.PI_F / 3.0)) * 0.5) + 0.5
    let blue = (sdl.sinf(seconds + ((sdl.PI_F * 2.0) / 3.0)) * 0.5) + 0.5

    sdl.set_render_draw_color_float(renderer, red, green, blue, sdl.ALPHA_OPAQUE_FLOAT)
    sdl.render_clear(renderer)
    sdl.render_present(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    sdl.set_app_metadata("Example Renderer Clear", "1.0", "com.example.renderer-clear")

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
