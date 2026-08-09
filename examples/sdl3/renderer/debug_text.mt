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
        "examples/renderer/debug-text",
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

    let charsize = sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
        sdl.render_debug_text(renderer, 272, 100, "Hello world!")
        sdl.render_debug_text(renderer, 224, 150, "This is some debug text.")

        sdl.set_render_draw_color(renderer, 51, 102, 255, sdl.ALPHA_OPAQUE)
        sdl.render_debug_text(renderer, 184, 200, "You can do it in different colors.")
        sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)

        sdl.set_render_scale(renderer, 4.0, 4.0)
        sdl.render_debug_text(renderer, 14, 65, "It can be scaled.")
        sdl.set_render_scale(renderer, 1.0, 1.0)
        sdl.render_debug_text(
            renderer,
            64,
            350,
            "This only does ASCII chars. So this laughing emoji won't draw: 🤣"
        )

        let running_text_x = (WINDOW_WIDTH - charsize * 46) / 2.0
        sdl.render_debug_text(
            renderer,
            running_text_x,
            400,
            f"(This program has been running for #{sdl.get_ticks() / 1000} seconds.)"
        )

        sdl.render_present(renderer)

    return 0
