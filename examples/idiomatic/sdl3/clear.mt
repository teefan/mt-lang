module examples.idiomatic.sdl3.clear

import std.sdl3 as sdl
import std.sdl3.runtime as sdl_rt

const window_width: int = 640
const window_height: int = 480
const window_title: str = "examples/renderer/clear"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ptr_uint = sdl.WINDOW_RESIZABLE

var window: sdl.Window
var renderer: sdl.Renderer


def pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(event):
        if event.type_ == uint<-sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let seconds = float<-sdl.get_ticks() / 1000.0
    let red = (sdl.sinf(seconds) * 0.5) + 0.5
    let green = (sdl.sinf(seconds + (sdl.PI_F / 3.0)) * 0.5) + 0.5
    let blue = (sdl.sinf(seconds + ((sdl.PI_F * 2.0) / 3.0)) * 0.5) + 0.5

    sdl.set_render_draw_color_float(renderer, red, green, blue, sdl.ALPHA_OPAQUE_FLOAT)
    sdl.render_clear(renderer)
    sdl.render_present(renderer)


def app_main() -> int:
    sdl.set_app_metadata("Example Renderer Clear", "1.0", "com.example.renderer-clear")

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


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return sdl_rt.run_app_no_args(argc, argv, app_main)
