module examples.idiomatic.sdl3.points

import std.sdl3 as sdl

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: str = "examples/renderer/points"
const presentation_mode: sdl.RendererLogicalPresentation = sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: usize = sdl.WINDOW_RESIZABLE
const point_count: i32 = 500
const min_pixels_per_second: f32 = 30.0
const max_pixels_per_second: f32 = 60.0

var window: ptr[sdl.Window]
var renderer: ptr[sdl.Renderer]
var last_time: usize = 0
var points: array[sdl.FPoint, 500] = zero[array[sdl.FPoint, 500]]()
var point_speeds: array[f32, 500] = zero[array[f32, 500]]()

def pump_events() -> bool:
    var event = sdl.Event(type = 0)

    while sdl.poll_event(out event):
        if event.quit.type == sdl.EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    let now = sdl.get_ticks()
    let elapsed = cast[f32](now - last_time) / 1000.0
    let width_f = cast[f32](window_width)
    let height_f = cast[f32](window_height)

    for index in range(0, point_count):
        let distance = elapsed * point_speeds[index]
        points[index].x += distance
        points[index].y += distance

        if points[index].x >= width_f or points[index].y >= height_f:
            if sdl.rand(2) != 0:
                points[index].x = sdl.randf() * width_f
                points[index].y = 0.0
            else:
                points[index].x = 0.0
                points[index].y = sdl.randf() * height_f

            point_speeds[index] = min_pixels_per_second + (sdl.randf() * (max_pixels_per_second - min_pixels_per_second))

    last_time = now

    sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
    sdl.render_clear(renderer)
    sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
    sdl.render_points(renderer, ro_addr(points[0]), point_count)
    sdl.render_present(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    sdl.set_app_metadata("Example Renderer Points", "1.0", "com.example.renderer-points")

    if not sdl.init(sdl.INIT_VIDEO):
        return 1
    defer sdl.quit()

    if not sdl.create_window_and_renderer(window_title, window_width, window_height, window_flags, out window, out renderer):
        return 1
    defer sdl.destroy_renderer(renderer)
    defer sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(renderer, window_width, window_height, presentation_mode):
        return 1

    for index in range(0, point_count):
        points[index].x = sdl.randf() * cast[f32](window_width)
        points[index].y = sdl.randf() * cast[f32](window_height)
        point_speeds[index] = min_pixels_per_second + (sdl.randf() * (max_pixels_per_second - min_pixels_per_second))

    last_time = sdl.get_ticks()

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return sdl.run_app(argc, argv, app_main)
