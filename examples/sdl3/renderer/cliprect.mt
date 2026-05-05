module examples.sdl3.renderer.cliprect

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: int = 640
const window_height: int = 480
const cliprect_size: int = 250
const cliprect_speed: float = 200.0
const window_title: cstr = c"examples/renderer/cliprect"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var cliprect_position: c.SDL_FPoint = zero[c.SDL_FPoint]
var cliprect_direction: c.SDL_FPoint = zero[c.SDL_FPoint]
var last_time: c.Uint64 = 0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let now = c.SDL_GetTicks()
    let elapsed = float<-(now - last_time) / 1000.0
    let distance = elapsed * cliprect_speed
    var cliprect = c.SDL_Rect(
        x = int<-c.SDL_roundf(cliprect_position.x),
        y = int<-c.SDL_roundf(cliprect_position.y),
        w = cliprect_size,
        h = cliprect_size,
    )

    cliprect_position.x += distance * cliprect_direction.x
    if cliprect_position.x < -float<-cliprect_size:
        cliprect_position.x = -float<-cliprect_size
        cliprect_direction.x = 1.0
    else:
        if cliprect_position.x >= float<-window_width:
            cliprect_position.x = float<-(window_width - 1)
            cliprect_direction.x = -1.0

    cliprect_position.y += distance * cliprect_direction.y
    if cliprect_position.y < -float<-cliprect_size:
        cliprect_position.y = -float<-cliprect_size
        cliprect_direction.y = 1.0
    else:
        if cliprect_position.y >= float<-window_height:
            cliprect_position.y = float<-(window_height - 1)
            cliprect_direction.y = -1.0

    cliprect.x = int<-c.SDL_roundf(cliprect_position.x)
    cliprect.y = int<-c.SDL_roundf(cliprect_position.y)
    c.SDL_SetRenderClipRect(renderer, ptr_of(cliprect))

    last_time = now

    c.SDL_SetRenderDrawColor(renderer, 33, 33, 33, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderTexture(renderer, texture, null, null)
    c.SDL_RenderPresent(renderer)


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example Renderer Clipping Rectangle", c"1.0", c"com.example.renderer-cliprect")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    cliprect_direction.x = 1.0
    cliprect_direction.y = 1.0
    last_time = c.SDL_GetTicks()

    let surface = c.SDL_LoadPNG(sample_texture_path)
    if surface == null:
        return 1
    defer c.SDL_DestroySurface(surface)

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
