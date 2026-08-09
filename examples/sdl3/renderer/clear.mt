import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/clear",
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

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        let now = sdl.get_ticks() / 1000.0
        let red = 0.5 + 0.5 * sdl.sinf(now)
        let green = 0.5 + 0.5 * sdl.sinf(now + sdl.PI_F * 2.0 / 3.0)
        let blue = 0.5 + 0.5 * sdl.sinf(now + sdl.PI_F * 4.0 / 3.0)
        if not sdl.set_render_draw_color_float(renderer, red, green, blue, sdl.ALPHA_OPAQUE_FLOAT):
            pass
        if not sdl.render_clear(renderer):
            pass
        if not sdl.render_present(renderer):
            pass

    return 0
