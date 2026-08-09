import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const RECT_COUNT: int = 16


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/rectangles",
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

    var rects: array[sdl.FRect, RECT_COUNT]

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        let now = sdl.get_ticks()
        let direction = if now % 2000 >= 1000: 1.0 else: -1.0
        let scale = (int<-(now % 1000) - 500) / 500.0 * direction

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        rects[0].x = 100.0
        rects[0].y = 100.0
        rects[0].w = 100.0 + 100.0 * scale
        rects[0].h = 100.0 + 100.0 * scale
        sdl.set_render_draw_color(renderer, 255, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_rect(renderer, rects[0])

        for i in 0..3:
            let size = (i + 1) * 50.0
            rects[i].w = size + size * scale
            rects[i].h = size + size * scale
            rects[i].x = (WINDOW_WIDTH - rects[i].w) / 2.0
            rects[i].y = (WINDOW_HEIGHT - rects[i].h) / 2.0
        sdl.set_render_draw_color(renderer, 0, 255, 0, sdl.ALPHA_OPAQUE)
        sdl.render_rects(renderer, span[sdl.FRect](data = ptr_of(rects[0]), len = 3))

        rects[0].x = 400.0
        rects[0].y = 50.0
        rects[0].w = 100.0 + 100.0 * scale
        rects[0].h = 50.0 + 50.0 * scale
        sdl.set_render_draw_color(renderer, 0, 0, 255, sdl.ALPHA_OPAQUE)
        sdl.render_fill_rect(renderer, rects[0])

        for i in 0..RECT_COUNT:
            let w = float<-WINDOW_WIDTH / RECT_COUNT
            let h = i * 8.0
            rects[i].x = i * w
            rects[i].y = WINDOW_HEIGHT - h
            rects[i].w = w
            rects[i].h = h
        sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
        sdl.render_fill_rects(renderer, rects)

        sdl.render_present(renderer)

    return 0
