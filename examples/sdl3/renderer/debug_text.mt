module examples.sdl3.renderer.debug_text

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/renderer/debug-text"
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const hello_text: cstr = c"Hello world!"
const body_text: cstr = c"This is some debug text."
const color_text: cstr = c"You can do it in different colors."
const scaled_text: cstr = c"It can be scaled."
const emoji_text: cstr = c"This only does ASCII chars. So this laughing emoji won't draw: 🤣"
const timer_format: cstr = c"(This program has been running for %zu seconds.)"

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    let charsize = i32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, 272.0, 100.0, hello_text)
    c.SDL_RenderDebugText(renderer, 224.0, 150.0, body_text)

    c.SDL_SetRenderDrawColor(renderer, 51, 102, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, 184.0, 200.0, color_text)
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)

    c.SDL_SetRenderScale(renderer, 4.0, 4.0)
    c.SDL_RenderDebugText(renderer, 14.0, 65.0, scaled_text)
    c.SDL_SetRenderScale(renderer, 1.0, 1.0)
    c.SDL_RenderDebugText(renderer, 64.0, 350.0, emoji_text)

    c.SDL_RenderDebugTextFormat(renderer, f32<-(window_width - (charsize * 46)) / 2.0, 400.0, timer_format, c.SDL_GetTicks() / 1000)
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Renderer Debug Texture", c"1.0", c"com.example.renderer-debug-text")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(ref_of(window)), ptr_of(ref_of(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    while pump_events():
        render_frame()

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
