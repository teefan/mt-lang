module examples.sdl3.renderer.rotating_textures

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/renderer/rotating-textures"
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
    let now = int<-c.SDL_GetTicks()
    let rotation = (float<-(now % 2000) / 2000.0) * 360.0
    let texture_width_f = float<-texture_width
    let texture_height_f = float<-texture_height

    var destination = c.SDL_FRect(
        x = float<-(window_width - texture_width) / 2.0,
        y = float<-(window_height - texture_height) / 2.0,
        w = texture_width_f,
        h = texture_height_f,
    )
    var center = c.SDL_FPoint(
        x = texture_width_f / 2.0,
        y = texture_height_f / 2.0,
    )

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderTextureRotated(renderer, texture, null, ptr_of(destination), double<-rotation, ptr_of(center), c.SDL_FlipMode.SDL_FLIP_NONE)
    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example Renderer Rotating Textures", c"1.0", c"com.example.renderer-rotating-textures")

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
