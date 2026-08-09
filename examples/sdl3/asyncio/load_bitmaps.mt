import std.sdl3 as sdl
import std.sdl3.runtime as runtime

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480
const TOTAL_TEXTURES: int = 4


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        sdl.show_simple_message_box(
            sdl.MESSAGEBOX_ERROR,
            "Couldn't initialize SDL!",
            f"#{sdl.get_error()}",
            null
        )
        return 1
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/asyncio/load-bitmaps",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        sdl.show_simple_message_box(
            sdl.MESSAGEBOX_ERROR,
            "Couldn't create window/renderer!",
            f"#{sdl.get_error()}",
            null
        )
        return 1
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(
        renderer,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
    ):
        pass

    let queue = sdl.create_async_io_queue() else:
        sdl.show_simple_message_box(
            sdl.MESSAGEBOX_ERROR,
            "Couldn't create async i/o queue!",
            f"#{sdl.get_error()}",
            null
        )
        return 1
    defer: sdl.destroy_async_io_queue(queue)

    let pngs = array[str, TOTAL_TEXTURES]("sample.png", "gamepad_front.png", "speaker.png", "icon2x.png")
    var textures: array[ptr[sdl.Texture]?, TOTAL_TEXTURES]
    let texture_rects = array[sdl.FRect, TOTAL_TEXTURES](
        sdl.FRect(x = 116, y = 156, w = 408, h = 167),
        sdl.FRect(x = 20, y = 200, w = 96, h = 60),
        sdl.FRect(x = 525, y = 180, w = 96, h = 96),
        sdl.FRect(x = 288, y = 375, w = 64, h = 64)
    )

    for i in 0..TOTAL_TEXTURES:
        var path = runtime.asset_path(pngs[i])
        sdl.load_file_async(path.as_str(), queue, unsafe: reinterpret[ptr[void]](ptr_uint<-i))
        path.release()

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        var outcome: sdl.AsyncIOOutcome = zero[sdl.AsyncIOOutcome]
        if sdl.get_async_io_result(queue, ptr_of(outcome)):
            if outcome.result == sdl.AsyncIOResult.SDL_ASYNCIO_COMPLETE:
                let index = int<-(unsafe: reinterpret[ptr_uint](outcome.userdata))
                let io = sdl.io_from_const_mem(outcome.buffer, outcome.bytes_transferred)
                if io != null:
                    let surface = sdl.load_png_io(io, true)
                    if surface != null:
                        textures[index] = sdl.create_texture_from_surface(renderer, surface)
                        if textures[index] == null:
                            sdl.show_simple_message_box(
                            sdl.MESSAGEBOX_ERROR,
                            "Couldn't create texture!",
                            f"#{sdl.get_error()}",
                            null
                        )
                            running = false
                        sdl.destroy_surface(surface)
            sdl.free(outcome.buffer)

        sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
        sdl.render_clear(renderer)
        for i in 0..TOTAL_TEXTURES:
            let tex = textures[i]
            if tex != null:
                sdl.render_texture(renderer, tex, null, const_ptr_of(texture_rects[i]))
        sdl.render_present(renderer)

    return 0
