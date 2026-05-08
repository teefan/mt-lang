module examples.idiomatic.sdl3.template

import std.sdl3 as sdl
import std.sdl3.runtime as sdl_rt

const window_width: int = 640
const window_height: int = 480
const window_title: str = "examples/template"
const window_flags: ptr_uint = sdl.WINDOW_RESIZABLE
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

var window: sdl.Window
var renderer: sdl.Renderer


function pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(event):
        if event.type_ == uint<-sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true


function render_frame() -> void:
    sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
    sdl.render_clear(renderer)
    sdl.render_present(renderer)


function app_main() -> int:
    sdl.set_app_metadata("Example Template", "1.0", "com.example.template")

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
