import std.sdl3 as sdl

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO | sdl.INIT_CAMERA):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/camera/read-and-draw",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    var device_count: int = 0
    let devices = sdl.get_cameras(ptr_of(device_count)) else:
        fatal(f"could not enumerate camera devices: #{sdl.get_error()}")
    defer: sdl.free(unsafe: ptr[void]<-devices)
    if device_count == 0:
        fatal("could not find any camera devices! Please connect a camera and try again.")

    let camera = sdl.open_camera(unsafe: devices[0], null) else:
        fatal(f"could not open camera: #{sdl.get_error()}")
    defer: sdl.close_camera(camera)

    var texture: ptr[sdl.Texture]? = null
    defer:
        if texture != null:
            sdl.destroy_texture(texture)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_CAMERA_DEVICE_DENIED:
                running = false

        var timestamp_ns: ptr_uint = 0
        let frame = sdl.acquire_camera_frame(camera, ptr_of(timestamp_ns))
        if frame != null:
            if texture == null:
                let frame_width = unsafe: frame.w
                let frame_height = unsafe: frame.h
                sdl.set_window_size(window, frame_width, frame_height)
                sdl.set_render_logical_presentation(
                    renderer,
                    frame_width,
                    frame_height,
                    sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
                )
                texture = sdl.create_texture(
                    renderer,
                    unsafe: frame.format,
                    sdl.TextureAccess.SDL_TEXTUREACCESS_STREAMING,
                    frame_width,
                    frame_height
                )
            if texture != null:
                sdl.update_texture(texture, null, unsafe: frame.pixels, unsafe: frame.pitch)
            sdl.release_camera_frame(camera, frame)

        sdl.set_render_draw_color(renderer, 0x99, 0x99, 0x99, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)
        if texture != null:
            sdl.render_texture(renderer, texture, null, null)
        sdl.render_present(renderer)

    return 0
