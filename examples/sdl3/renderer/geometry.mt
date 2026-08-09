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
        "examples/renderer/geometry",
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
        let direction = if now % 2000 >= 1000: 1.0 else: -1.0
        let scale = (int<-(now % 1000) - 500) / 500.0 * direction
        let size = 200.0 + 200.0 * scale

        sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        var vertices: array[sdl.Vertex, 4]
        vertices[0].position.x = WINDOW_WIDTH / 2.0
        vertices[0].position.y = (WINDOW_HEIGHT - size) / 2.0
        vertices[0].color.r = 1.0
        vertices[0].color.a = 1.0
        vertices[1].position.x = (WINDOW_WIDTH + size) / 2.0
        vertices[1].position.y = (WINDOW_HEIGHT + size) / 2.0
        vertices[1].color.g = 1.0
        vertices[1].color.a = 1.0
        vertices[2].position.x = (WINDOW_WIDTH - size) / 2.0
        vertices[2].position.y = (WINDOW_HEIGHT + size) / 2.0
        vertices[2].color.b = 1.0
        vertices[2].color.a = 1.0
        sdl.render_geometry(renderer, null, const_ptr_of(vertices[0]), 3, null, 0)

        vertices[0].position.x = 10.0
        vertices[0].position.y = 10.0
        vertices[0].color.r = 1.0
        vertices[0].color.g = 1.0
        vertices[0].color.b = 1.0
        vertices[0].color.a = 1.0
        vertices[0].tex_coord.x = 0.0
        vertices[0].tex_coord.y = 0.0
        vertices[1].position.x = 150.0
        vertices[1].position.y = 10.0
        vertices[1].color.r = 1.0
        vertices[1].color.g = 1.0
        vertices[1].color.b = 1.0
        vertices[1].color.a = 1.0
        vertices[1].tex_coord.x = 1.0
        vertices[1].tex_coord.y = 0.0
        vertices[2].position.x = 10.0
        vertices[2].position.y = 150.0
        vertices[2].color.r = 1.0
        vertices[2].color.g = 1.0
        vertices[2].color.b = 1.0
        vertices[2].color.a = 1.0
        vertices[2].tex_coord.x = 0.0
        vertices[2].tex_coord.y = 1.0
        sdl.render_geometry(renderer, texture, const_ptr_of(vertices[0]), 3, null, 0)

        for i in 0..3:
            vertices[i].position.x += 450.0
        vertices[3].position.x = 600.0
        vertices[3].position.y = 150.0
        vertices[3].color.r = 1.0
        vertices[3].color.g = 1.0
        vertices[3].color.b = 1.0
        vertices[3].color.a = 1.0
        vertices[3].tex_coord.x = 1.0
        vertices[3].tex_coord.y = 1.0
        let indices = array[int, 6](0, 1, 2, 1, 2, 3)
        sdl.render_geometry(renderer, texture, const_ptr_of(vertices[0]), 4, const_ptr_of(indices[0]), 6)

        sdl.render_present(renderer)

    return 0
