import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const LINE_POINT_COUNT: int = 9


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/lines",
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

    var line_points = array[sdl.FPoint, LINE_POINT_COUNT](
        sdl.FPoint(x = 100.0, y = 354.0),
        sdl.FPoint(x = 220.0, y = 230.0),
        sdl.FPoint(x = 140.0, y = 230.0),
        sdl.FPoint(x = 320.0, y = 100.0),
        sdl.FPoint(x = 500.0, y = 230.0),
        sdl.FPoint(x = 420.0, y = 230.0),
        sdl.FPoint(x = 540.0, y = 354.0),
        sdl.FPoint(x = 400.0, y = 354.0),
        sdl.FPoint(x = 100.0, y = 354.0)
    )

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        sdl.set_render_draw_color(renderer, 100, 100, 100, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        sdl.set_render_draw_color(renderer, 127, 49, 32, sdl.ALPHA_OPAQUE)
        sdl.render_line(renderer, 240, 450, 400, 450)
        sdl.render_line(renderer, 240, 356, 400, 356)
        sdl.render_line(renderer, 240, 356, 240, 450)
        sdl.render_line(renderer, 400, 356, 400, 450)

        sdl.set_render_draw_color(renderer, 0, 255, 0, sdl.ALPHA_OPAQUE)
        sdl.render_lines(renderer, line_points)

        for i in 0..360:
            let size = 30.0
            let x = 320.0
            let y = 95.0 - size / 2.0
            let r = i * (sdl.PI_F / 180.0)
            sdl.set_render_draw_color(
                renderer,
                ubyte<-sdl.rand(256),
                ubyte<-sdl.rand(256),
                ubyte<-sdl.rand(256),
                sdl.ALPHA_OPAQUE
            )
            sdl.render_line(renderer, x, y, x + sdl.cosf(r) * size, y + sdl.sinf(r) * size)

        sdl.render_present(renderer)

    return 0
