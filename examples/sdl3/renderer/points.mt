import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const NUM_POINTS: int = 500
const MIN_PIXELS_PER_SECOND: float = 30.0
const MAX_PIXELS_PER_SECOND: float = 60.0


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/points",
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

    var points: array[sdl.FPoint, NUM_POINTS]
    var point_speeds: array[float, NUM_POINTS]
    for i in 0..NUM_POINTS:
        points[i] = sdl.FPoint(
            x = sdl.randf() * WINDOW_WIDTH,
            y = sdl.randf() * WINDOW_HEIGHT
        )
        point_speeds[i] = MIN_PIXELS_PER_SECOND + (sdl.randf() * (MAX_PIXELS_PER_SECOND - MIN_PIXELS_PER_SECOND))

    var last_time = sdl.get_ticks()

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        let now = sdl.get_ticks()
        let elapsed = (now - last_time) / 1000.0
        for i in 0..NUM_POINTS:
            let distance = elapsed * point_speeds[i]
            points[i].x += distance
            points[i].y += distance
            if points[i].x >= WINDOW_WIDTH or points[i].y >= WINDOW_HEIGHT:
                if sdl.rand(2) != 0:
                    points[i].x = sdl.randf() * WINDOW_WIDTH
                    points[i].y = 0.0
                else:
                    points[i].x = 0.0
                    points[i].y = sdl.randf() * WINDOW_HEIGHT
                point_speeds[i] = MIN_PIXELS_PER_SECOND +
                    (sdl.randf() * (MAX_PIXELS_PER_SECOND - MIN_PIXELS_PER_SECOND))
        last_time = now

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)
        sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
        sdl.render_points(renderer, points)

        sdl.render_present(renderer)

    return 0
