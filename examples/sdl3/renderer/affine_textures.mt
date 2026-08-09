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
        "examples/renderer/affine-textures",
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

        let x0 = 0.5 * WINDOW_WIDTH
        let y0 = 0.5 * WINDOW_HEIGHT
        let px = (if WINDOW_WIDTH < WINDOW_HEIGHT: WINDOW_WIDTH else: WINDOW_HEIGHT) / sdl.sqrtf(3.0)

        let now = sdl.get_ticks()
        let rad = (int<-(now % 2000)) / 2000.0 * sdl.PI_F * 2
        let cos_value = sdl.cosf(rad)
        let sin_value = sdl.sinf(rad)
        let k = array[float, 3](
            3.0 / sdl.sqrtf(50.0),
            4.0 / sdl.sqrtf(50.0),
            5.0 / sdl.sqrtf(50.0)
        )
        var mat: array[float, 9]
        mat[0] = cos_value + (1.0 - cos_value) * k[0] * k[0]
        mat[1] = -sin_value * k[2] + (1.0 - cos_value) * k[0] * k[1]
        mat[2] = sin_value * k[1] + (1.0 - cos_value) * k[0] * k[2]
        mat[3] = sin_value * k[2] + (1.0 - cos_value) * k[0] * k[1]
        mat[4] = cos_value + (1.0 - cos_value) * k[1] * k[1]
        mat[5] = -sin_value * k[0] + (1.0 - cos_value) * k[1] * k[2]
        mat[6] = -sin_value * k[1] + (1.0 - cos_value) * k[0] * k[2]
        mat[7] = sin_value * k[0] + (1.0 - cos_value) * k[1] * k[2]
        mat[8] = cos_value + (1.0 - cos_value) * k[2] * k[2]

        var corners: array[float, 16]
        for i in 0..8:
            let x = if (i & 1) != 0: -0.5 else: 0.5
            let y = if (i & 2) != 0: -0.5 else: 0.5
            let z = if (i & 4) != 0: -0.5 else: 0.5
            corners[2 * i] = mat[0] * x + mat[1] * y + mat[2] * z
            corners[1 + 2 * i] = mat[3] * x + mat[4] * y + mat[5] * z

        sdl.set_render_draw_color(renderer, 0x42, 0x87, 0xf5, sdl.ALPHA_OPAQUE)
        sdl.render_clear(renderer)

        for i in 1..7:
            let dir = 3 & (if (i & 4) != 0: ~i else: i)
            let odd = (i & 1) ^ ((i & 2) >> 1) ^ ((i & 4) >> 2)
            if 0 < (if odd != 0: 1.0 else: -1.0) * mat[5 + dir]:
                continue
            var origin_index = 1 << ((dir - 1) % 3)
            var right_index = (1 << ((dir + odd) % 3)) | origin_index
            var down_index = (1 << ((dir + (odd ^ 1)) % 3)) | origin_index
            if odd == 0:
                origin_index ^= 7
                right_index ^= 7
                down_index ^= 7
            let origin = sdl.FPoint(
                x = x0 + px * corners[2 * origin_index],
                y = y0 + px * corners[1 + 2 * origin_index]
            )
            let right = sdl.FPoint(
                x = x0 + px * corners[2 * right_index],
                y = y0 + px * corners[1 + 2 * right_index]
            )
            let down = sdl.FPoint(
                x = x0 + px * corners[2 * down_index],
                y = y0 + px * corners[1 + 2 * down_index]
            )
            sdl.render_texture_affine(
                renderer,
                texture,
                null,
                const_ptr_of(origin),
                const_ptr_of(right),
                const_ptr_of(down)
            )

        sdl.render_present(renderer)

    return 0
