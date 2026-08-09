import std.sdl3 as sdl
import std.sdl3.runtime as runtime

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const CLIPRECT_SIZE: int = 250
const CLIPRECT_SPEED: float = 200.0


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/cliprect",
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

    var cliprect_position = sdl.FPoint(x = 0.0, y = 0.0)
    var cliprect_direction = sdl.FPoint(x = 1.0, y = 1.0)
    var last_time = sdl.get_ticks()

    var path = runtime.asset_path("sample.png")
    defer: path.release()
    let surface = sdl.load_png(path.as_str()) else:
        fatal(f"could not load sample.png: #{sdl.get_error()}")
    let texture = sdl.create_texture_from_surface(renderer, surface) else:
        fatal(f"could not create texture: #{sdl.get_error()}")
    sdl.destroy_surface(surface)
    defer: sdl.destroy_texture(texture)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        let cliprect = sdl.Rect(
            x = int<-sdl.roundf(cliprect_position.x),
            y = int<-sdl.roundf(cliprect_position.y),
            w = CLIPRECT_SIZE,
            h = CLIPRECT_SIZE
        )
        let now = sdl.get_ticks()
        let elapsed = (now - last_time) / 1000.0
        let distance = elapsed * CLIPRECT_SPEED

        cliprect_position.x += distance * cliprect_direction.x
        if cliprect_position.x < -CLIPRECT_SIZE:
            cliprect_position.x = -CLIPRECT_SIZE
            cliprect_direction.x = 1.0
        else if cliprect_position.x >= WINDOW_WIDTH:
            cliprect_position.x = WINDOW_WIDTH - 1
            cliprect_direction.x = -1.0

        cliprect_position.y += distance * cliprect_direction.y
        if cliprect_position.y < -CLIPRECT_SIZE:
            cliprect_position.y = -CLIPRECT_SIZE
            cliprect_direction.y = 1.0
        else if cliprect_position.y >= WINDOW_HEIGHT:
            cliprect_position.y = WINDOW_HEIGHT - 1
            cliprect_direction.y = -1.0
        sdl.set_render_clip_rect(renderer, const_ptr_of(cliprect))

        last_time = now

        sdl.set_render_draw_color(renderer, 33, 33, 33, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)
        sdl.render_texture(renderer, texture, null, null)
        sdl.render_present(renderer)

    return 0
