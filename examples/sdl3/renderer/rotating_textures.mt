import std.sdl3 as sdl
import std.sdl3.runtime as runtime

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/rotating-textures",
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

    var path = runtime.asset_path("sample.png")
    defer: path.release()
    let surface = sdl.load_png(path.as_str()) else:
        fatal(f"could not load sample.png: #{sdl.get_error()}")
    let texture_width = unsafe: surface.w
    let texture_height = unsafe: surface.h
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

        let now = sdl.get_ticks()
        let rotation = (int<-(now % 2000)) / 2000.0 * 360.0

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        var dst_rect: sdl.FRect
        dst_rect.x = (WINDOW_WIDTH - texture_width) / 2.0
        dst_rect.y = (WINDOW_HEIGHT - texture_height) / 2.0
        dst_rect.w = texture_width
        dst_rect.h = texture_height
        var center: sdl.FPoint
        center.x = texture_width / 2.0
        center.y = texture_height / 2.0
        sdl.render_texture_rotated(
            renderer,
            texture,
            null,
            const_ptr_of(dst_rect),
            double<-rotation,
            const_ptr_of(center),
            sdl.FlipMode.SDL_FLIP_NONE
        )

        sdl.render_present(renderer)

    return 0
