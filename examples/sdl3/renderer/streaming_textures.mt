module examples.sdl3.renderer.streaming_textures

import std.c.sdl3 as c

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/renderer/streaming-textures"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE
const texture_size: int = 150

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let now = int<-c.SDL_GetTicks()
    let direction = if (now % 2000) >= 1000: 1.0 else: -1.0
    let scale = (float<-((now % 1000) - 500) / 500.0) * direction

    var surface: ptr[c.SDL_Surface]
    if c.SDL_LockTextureToSurface(texture, null, ptr_of(surface)):
        unsafe:
            let format_details = c.SDL_GetPixelFormatDetails(surface.format)
            let black = c.SDL_MapRGB(format_details, null, 0, 0, 0)
            let green = c.SDL_MapRGB(format_details, null, 0, 255, 0)
            var strip = c.SDL_Rect(x = 0, y = 0, w = texture_size, h = texture_size / 10)

            c.SDL_FillSurfaceRect(surface, null, black)

            strip.y = int<-(float<-(texture_size - strip.h) * ((scale + 1.0) / 2.0))
            c.SDL_FillSurfaceRect(surface, ptr_of(strip), green)

        c.SDL_UnlockTexture(texture)

    var destination = c.SDL_FRect(
        x = float<-(window_width - texture_size) / 2.0,
        y = float<-(window_height - texture_size) / 2.0,
        w = float<-texture_size,
        h = float<-texture_size,
    )

    c.SDL_SetRenderDrawColor(renderer, 66, 66, 66, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderTexture(renderer, texture, null, ptr_of(destination))
    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example Renderer Streaming Textures", c"1.0", c"com.example.renderer-streaming-textures")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    let created_texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888,
        c.SDL_TextureAccess.SDL_TEXTUREACCESS_STREAMING,
        texture_size,
        texture_size,
    )
    if created_texture == null:
        return 1
    texture = created_texture
    defer c.SDL_DestroyTexture(texture)

    while pump_events():
        render_frame()

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return c.SDL_RunApp(argc, argv, app_main, null)
