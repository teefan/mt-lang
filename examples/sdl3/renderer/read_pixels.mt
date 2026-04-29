module examples.sdl3.renderer.read_pixels

import std.c.sdl3 as c

const sample_texture_path: cstr = c"../resources/sample.png"
const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/read-pixels"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = cast[u64](c.SDL_WINDOW_RESIZABLE)

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var texture_width: i32 = 0
var texture_height: i32 = 0
var converted_texture: ptr[c.SDL_Texture]?
var converted_texture_width: i32 = 0
var converted_texture_height: i32 = 0

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> bool:
    let now = cast[i32](c.SDL_GetTicks())
    let rotation = (cast[f32](now % 2000) / 2000.0) * 360.0

    var center = c.SDL_FPoint(
        x = cast[f32](texture_width) / 2.0,
        y = cast[f32](texture_height) / 2.0,
    )
    var destination = c.SDL_FRect(
        x = cast[f32](window_width - texture_width) / 2.0,
        y = cast[f32](window_height - texture_height) / 2.0,
        w = cast[f32](texture_width),
        h = cast[f32](texture_height),
    )

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderTextureRotated(renderer, texture, null, raw(addr(destination)), cast[f64](rotation), raw(addr(center)), c.SDL_FlipMode.SDL_FLIP_NONE)

    var surface = c.SDL_RenderReadPixels(renderer, null)
    var processed_surface: ptr[c.SDL_Surface]? = surface

    if surface != null:
        unsafe:
            if (deref(surface).format != c.SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888) and (deref(surface).format != c.SDL_PixelFormat.SDL_PIXELFORMAT_BGRA8888):
                let converted = c.SDL_ConvertSurface(surface, c.SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888)
                c.SDL_DestroySurface(surface)
                processed_surface = converted

        if processed_surface != null:
            unsafe:
                if (deref(processed_surface).w != converted_texture_width) or (deref(processed_surface).h != converted_texture_height):
                    if converted_texture != null:
                        c.SDL_DestroyTexture(converted_texture)

                    let rebuilt_texture = c.SDL_CreateTexture(
                        renderer,
                        c.SDL_PixelFormat.SDL_PIXELFORMAT_RGBA8888,
                        c.SDL_TextureAccess.SDL_TEXTUREACCESS_STREAMING,
                        deref(processed_surface).w,
                        deref(processed_surface).h,
                    )
                    if rebuilt_texture == null:
                        c.SDL_DestroySurface(processed_surface)
                        return false

                    converted_texture = rebuilt_texture
                    converted_texture_width = deref(processed_surface).w
                    converted_texture_height = deref(processed_surface).h

                for y in range(0, deref(processed_surface).h):
                    let row_bytes = cast[ptr[c.Uint8]](deref(processed_surface).pixels) + (y * deref(processed_surface).pitch)
                    let row_pixels = cast[ptr[c.Uint32]](row_bytes)

                    for x in range(0, deref(processed_surface).w):
                        let pixel_bytes = cast[ptr[c.Uint8]](row_pixels + x)
                        let average = (cast[u32](deref(pixel_bytes + 1)) + cast[u32](deref(pixel_bytes + 2)) + cast[u32](deref(pixel_bytes + 3))) / 3

                        if average == 0:
                            deref(pixel_bytes + 0) = 0xFF
                            deref(pixel_bytes + 1) = 0
                            deref(pixel_bytes + 2) = 0
                            deref(pixel_bytes + 3) = 0xFF
                        else:
                            deref(pixel_bytes + 1) = if average > 50 then 0xFF else 0
                            deref(pixel_bytes + 2) = if average > 50 then 0xFF else 0
                            deref(pixel_bytes + 3) = if average > 50 then 0xFF else 0

                if converted_texture != null:
                    c.SDL_UpdateTexture(converted_texture, null, deref(processed_surface).pixels, deref(processed_surface).pitch)
                    c.SDL_DestroySurface(processed_surface)

                    destination.x = 0.0
                    destination.y = 0.0
                    destination.w = cast[f32](window_width) / 4.0
                    destination.h = cast[f32](window_height) / 4.0
                    c.SDL_RenderTexture(renderer, converted_texture, null, raw(addr(destination)))
                else:
                    c.SDL_DestroySurface(processed_surface)
                    return false

    c.SDL_RenderPresent(renderer)
    return true

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Read Pixels", c"1.0", c"com.example.renderer-read-pixels")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
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
        texture_width = deref(surface).w
        texture_height = deref(surface).h

    let created_texture = c.SDL_CreateTextureFromSurface(renderer, surface)
    if created_texture == null:
        return 1
    texture = created_texture
    defer:
        if converted_texture != null:
            c.SDL_DestroyTexture(converted_texture)
        c.SDL_DestroyTexture(texture)

    while pump_events():
        if not render_frame():
            return 1

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
