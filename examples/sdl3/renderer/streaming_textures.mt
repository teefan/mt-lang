import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const TEXTURE_SIZE: int = 150


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/renderer/streaming-textures",
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

    let texture = sdl.create_texture(
        renderer,
        sdl.PixelFormat.SDL_PIXELFORMAT_RGBA8888,
        sdl.TextureAccess.SDL_TEXTUREACCESS_STREAMING,
        TEXTURE_SIZE,
        TEXTURE_SIZE
    ) else:
        fatal(f"could not create streaming texture: #{sdl.get_error()}")
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

        var locked_surface: ptr[sdl.Surface]
        if sdl.lock_texture_to_surface(texture, null, ptr_of(locked_surface)):
            let details = sdl.get_pixel_format_details(unsafe: locked_surface.format) else:
                fatal(f"could not get pixel format details: #{sdl.get_error()}")
            sdl.fill_surface_rect(locked_surface, null, sdl.map_rgb(details, null, 0, 0, 0))

            var strip: sdl.Rect
            strip.w = TEXTURE_SIZE
            strip.h = TEXTURE_SIZE / 10
            strip.x = 0
            strip.y = int<-((TEXTURE_SIZE - strip.h) * ((scale + 1.0) / 2.0))
            sdl.fill_surface_rect(locked_surface, const_ptr_of(strip), sdl.map_rgb(details, null, 0, 255, 0))
            sdl.unlock_texture(texture)

        sdl.set_render_draw_color(renderer, 66, 66, 66, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        var dst_rect: sdl.FRect
        dst_rect.x = (WINDOW_WIDTH - TEXTURE_SIZE) / 2.0
        dst_rect.y = (WINDOW_HEIGHT - TEXTURE_SIZE) / 2.0
        dst_rect.w = TEXTURE_SIZE
        dst_rect.h = TEXTURE_SIZE
        sdl.render_texture(renderer, texture, null, const_ptr_of(dst_rect))

        sdl.render_present(renderer)

    return 0
