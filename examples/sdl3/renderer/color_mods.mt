module examples.sdl3.renderer.color_mods

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/color-mods"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var texture_width: i32 = 0
var texture_height: i32 = 0


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    let now = f64<-c.SDL_GetTicks() / 1000.0
    let red = f32<-(0.5 + (0.5 * c.SDL_sin(now)))
    let green = f32<-(0.5 + (0.5 * c.SDL_sin(now + ((c.SDL_PI_D * 2.0) / 3.0))))
    let blue = f32<-(0.5 + (0.5 * c.SDL_sin(now + ((c.SDL_PI_D * 4.0) / 3.0))))

    var destination = c.SDL_FRect(x = 0.0, y = 0.0, w = f32<-texture_width, h = f32<-texture_height)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    c.SDL_SetTextureColorModFloat(texture, 0.0, 0.0, 1.0)
    c.SDL_RenderTexture(renderer, texture, null, ptr_of(ref_of(destination)))

    destination.x = f32<-(window_width - texture_width) / 2.0
    destination.y = f32<-(window_height - texture_height) / 2.0
    c.SDL_SetTextureColorModFloat(texture, red, green, blue)
    c.SDL_RenderTexture(renderer, texture, null, ptr_of(ref_of(destination)))

    destination.x = f32<-(window_width - texture_width)
    destination.y = f32<-(window_height - texture_height)
    c.SDL_SetTextureColorModFloat(texture, 1.0, 0.0, 0.0)
    c.SDL_RenderTexture(renderer, texture, null, ptr_of(ref_of(destination)))

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Color Mods", c"1.0", c"com.example.renderer-color-mods")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
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


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
