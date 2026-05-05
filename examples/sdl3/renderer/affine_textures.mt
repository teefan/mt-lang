module examples.sdl3.renderer.affine_textures

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/renderer/affine-textures"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var texture_width: int = 0
var texture_height: int = 0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let x0 = 0.5 * float<-window_width
    let y0 = 0.5 * float<-window_height
    let min_dimension = if window_width < window_height: window_width else: window_height
    let px = float<-min_dimension / c.SDL_sqrtf(3.0)

    let now = int<-c.SDL_GetTicks()
    let rad = (float<-(now % 2000) / 2000.0) * c.SDL_PI_F * 2.0
    let cosine = c.SDL_cosf(rad)
    let sine = c.SDL_sinf(rad)
    let k = array[float, 3](
        3.0 / c.SDL_sqrtf(50.0),
        4.0 / c.SDL_sqrtf(50.0),
        5.0 / c.SDL_sqrtf(50.0),
    )
    var mat = array[float, 9](
        cosine + ((1.0 - cosine) * k[0] * k[0]),
        (-sine * k[2]) + ((1.0 - cosine) * k[0] * k[1]),
        (sine * k[1]) + ((1.0 - cosine) * k[0] * k[2]),
        (sine * k[2]) + ((1.0 - cosine) * k[0] * k[1]),
        cosine + ((1.0 - cosine) * k[1] * k[1]),
        (-sine * k[0]) + ((1.0 - cosine) * k[1] * k[2]),
        (-sine * k[1]) + ((1.0 - cosine) * k[0] * k[2]),
        (sine * k[0]) + ((1.0 - cosine) * k[1] * k[2]),
        cosine + ((1.0 - cosine) * k[2] * k[2]),
    )
    let bit_masks = array[int, 3](1, 2, 4)
    var corners = zero[array[float, 16]]

    for index in 0..8:
        let x = if (index & 1) != 0: float<-(-0.5) else: float<-0.5
        let y = if (index & 2) != 0: float<-(-0.5) else: float<-0.5
        let z = if (index & 4) != 0: float<-(-0.5) else: float<-0.5
        corners[0 + (2 * index)] = (mat[0] * x) + (mat[1] * y) + (mat[2] * z)
        corners[1 + (2 * index)] = (mat[3] * x) + (mat[4] * y) + (mat[5] * z)

    c.SDL_SetRenderDrawColor(renderer, 0x42, 0x87, 0xF5, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    for index in 1..7:
        let dir = if (index & 4) != 0: 7 - index else: index
        let odd = (
            (if (index & 1) != 0: 1 else: 0) +
            (if (index & 2) != 0: 1 else: 0) +
            (if (index & 4) != 0: 1 else: 0)
        ) % 2

        if 0.0 < ((if odd == 1: 1.0 else: -1.0) * mat[5 + dir]):
            continue

        var origin_index = bit_masks[(dir - 1) % 3]
        var right_index = bit_masks[(dir + odd) % 3] + origin_index
        var down_index = bit_masks[(dir + (1 - odd)) % 3] + origin_index

        if odd == 0:
            origin_index = 7 - origin_index
            right_index = 7 - right_index
            down_index = 7 - down_index

        var origin = c.SDL_FPoint(
            x = x0 + (px * corners[0 + (2 * origin_index)]),
            y = y0 + (px * corners[1 + (2 * origin_index)]),
        )
        var right = c.SDL_FPoint(
            x = x0 + (px * corners[0 + (2 * right_index)]),
            y = y0 + (px * corners[1 + (2 * right_index)]),
        )
        var down = c.SDL_FPoint(
            x = x0 + (px * corners[0 + (2 * down_index)]),
            y = y0 + (px * corners[1 + (2 * down_index)]),
        )

        c.SDL_RenderTextureAffine(renderer, texture, null, ptr_of(origin), ptr_of(right), ptr_of(down))

    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example Renderer Affine Textures", c"1.0", c"com.example.renderer-affine-textures")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    let surface = c.SDL_LoadPNG(sample_texture_path)
    if surface == null:
        return 1
    defer c.SDL_DestroySurface(surface)

    unsafe:
        texture_width = surface.w
        texture_height = surface.h

    let created_texture = c.SDL_CreateTextureFromSurface(renderer, surface)
    if created_texture == null:
        return 1
    texture = created_texture
    defer c.SDL_DestroyTexture(texture)

    while pump_events():
        render_frame()

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return c.SDL_RunApp(argc, argv, app_main, null)
