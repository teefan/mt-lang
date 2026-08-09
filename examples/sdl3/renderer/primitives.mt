import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const POINT_COUNT: int = 500


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/primitives",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(
        renderer,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
    ):
        pass

    var points: array[sdl.FPoint, POINT_COUNT]
    for i in 0..POINT_COUNT:
        points[i] = sdl.FPoint(
            x = sdl.randf() * 440.0 + 100.0,
            y = sdl.randf() * 280.0 + 100.0
        )

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        sdl.set_render_draw_color(renderer, 33, 33, 33, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        sdl.set_render_draw_color(renderer, 0, 0, 255, sdl.ALPHA_OPAQUE)
        sdl.render_fill_rect(renderer, sdl.FRect(x = 100.0, y = 100.0, w = 440.0, h = 280.0))

        sdl.set_render_draw_color(renderer, 255, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_points(renderer, points)

        sdl.set_render_draw_color(renderer, 0, 255, 0, sdl.ALPHA_OPAQUE)
        sdl.render_rect(renderer, sdl.FRect(x = 130.0, y = 130.0, w = 380.0, h = 220.0))

        sdl.set_render_draw_color(renderer, 255, 255, 0, sdl.ALPHA_OPAQUE)
        sdl.render_line(renderer, 0, 0, float<-WINDOW_WIDTH, float<-WINDOW_HEIGHT)
        sdl.render_line(renderer, 0, float<-WINDOW_HEIGHT, float<-WINDOW_WIDTH, 0)

        sdl.render_present(renderer)

    return 0
