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
        "examples/renderer/read-pixels",
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

    var converted_texture: ptr[sdl.Texture]? = null
    var converted_texture_width: int = 0
    var converted_texture_height: int = 0
    defer:
        if converted_texture != null:
            sdl.destroy_texture(converted_texture)

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

        var read_surface = sdl.render_read_pixels(renderer, null)
        if read_surface != null:
            let surface_format = unsafe: read_surface.format
            if (
                surface_format != sdl.PixelFormat.SDL_PIXELFORMAT_RGBA8888
                and surface_format != sdl.PixelFormat.SDL_PIXELFORMAT_BGRA8888
            ):
                let converted = sdl.convert_surface(read_surface, sdl.PixelFormat.SDL_PIXELFORMAT_RGBA8888)
                if converted != null:
                    sdl.destroy_surface(read_surface)
                    read_surface = converted

            let surface_width = unsafe: read_surface.w
            let surface_height = unsafe: read_surface.h
            if surface_width != converted_texture_width or surface_height != converted_texture_height:
                if converted_texture != null:
                    sdl.destroy_texture(converted_texture)
                converted_texture = sdl.create_texture(
                    renderer,
                    sdl.PixelFormat.SDL_PIXELFORMAT_RGBA8888,
                    sdl.TextureAccess.SDL_TEXTUREACCESS_STREAMING,
                    surface_width,
                    surface_height
                )
                if converted_texture == null:
                    fatal(f"could not recreate conversion texture: #{sdl.get_error()}")
                converted_texture_width = surface_width
                converted_texture_height = surface_height

            unsafe:
                for y in 0..surface_height:
                    let row = ptr[ubyte]<-read_surface.pixels + y * read_surface.pitch
                    for x in 0..surface_width:
                        let pixel = ptr[ubyte]<-(ptr[uint]<-row + x)
                        let average = (uint<-pixel[1] + uint<-pixel[2] + uint<-pixel[3]) / 3
                        if average == 0:
                            pixel[0] = 0xFF
                            pixel[3] = 0xFF
                            pixel[1] = 0
                            pixel[2] = 0
                        else:
                            let shade: ubyte = if average > 50: 0xFF else: 0x00
                            pixel[1] = shade
                            pixel[2] = shade
                            pixel[3] = shade

            let active_texture = converted_texture else:
                fatal(f"could not recreate conversion texture: #{sdl.get_error()}")
            let surface_pixels = unsafe: read_surface.pixels
            let surface_pitch = unsafe: read_surface.pitch
            sdl.update_texture(active_texture, null, surface_pixels, surface_pitch)
            sdl.destroy_surface(read_surface)

            dst_rect.x = 0.0
            dst_rect.y = 0.0
            dst_rect.w = WINDOW_WIDTH / 4.0
            dst_rect.h = WINDOW_HEIGHT / 4.0
            sdl.render_texture(renderer, active_texture, null, const_ptr_of(dst_rect))

        sdl.render_present(renderer)

    return 0
