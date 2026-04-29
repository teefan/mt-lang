module examples.idiomatic.sdl3.template

import std.sdl3 as sdl

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: str = "examples/template"
const window_flags: usize = sdl.WINDOW_RESIZABLE
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

var window: ptr[sdl.Window]
var renderer: ptr[sdl.Renderer]

def pump_events() -> bool:
    var event = sdl.Event(type = 0)

    while sdl.poll_event(out event):
        if event.quit.type == sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
    sdl.render_clear(renderer)
    sdl.render_present(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    sdl.set_app_metadata("Example Template", "1.0", "com.example.template")

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
