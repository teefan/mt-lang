module examples.sdl3.template

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/template"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Template", c"1.0", c"com.example.template")

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
