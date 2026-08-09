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
        "examples/renderer/viewport",
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

        var dst_rect: sdl.FRect
        dst_rect.x = 0.0
        dst_rect.y = 0.0
        dst_rect.w = texture_width
        dst_rect.h = texture_height
        var viewport: sdl.Rect

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        viewport.x = 0
        viewport.y = 0
        viewport.w = WINDOW_WIDTH / 2
        viewport.h = WINDOW_HEIGHT / 2
        sdl.set_render_viewport(renderer, null)
        sdl.render_texture(renderer, texture, null, const_ptr_of(dst_rect))

        viewport.x = WINDOW_WIDTH / 2
        viewport.y = WINDOW_HEIGHT / 2
        viewport.w = WINDOW_WIDTH / 2
        viewport.h = WINDOW_HEIGHT / 2
        sdl.set_render_viewport(renderer, const_ptr_of(viewport))
        sdl.render_texture(renderer, texture, null, const_ptr_of(dst_rect))

        viewport.x = 0
        viewport.y = WINDOW_HEIGHT - WINDOW_HEIGHT / 5
        viewport.w = WINDOW_WIDTH / 5
        viewport.h = WINDOW_HEIGHT / 5
        sdl.set_render_viewport(renderer, const_ptr_of(viewport))
        sdl.render_texture(renderer, texture, null, const_ptr_of(dst_rect))

        viewport.x = 100
        viewport.y = 200
        viewport.w = WINDOW_WIDTH
        viewport.h = WINDOW_HEIGHT
        sdl.set_render_viewport(renderer, const_ptr_of(viewport))
        dst_rect.y = -50.0
        sdl.render_texture(renderer, texture, null, const_ptr_of(dst_rect))

        sdl.render_present(renderer)

    return 0
