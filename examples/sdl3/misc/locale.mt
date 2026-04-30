module examples.sdl3.misc.locale

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/misc/locale"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true

def render_frame() -> void:
    let frame = c.SDL_FRect(x = 0.0, y = 0.0, w = 640.0, h = 480.0)
    var msgbuf = zero[array[char, 128]]()
    var count: i32 = 0
    let locales_memory = c.SDL_GetPreferredLocales(raw(addr(count)))

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)

    if locales_memory == null:
        let error_text = c.SDL_GetError()
        let x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(error_text))) / 2.0)
        c.SDL_RenderDebugText(renderer, x, frame.y, error_text)
    else:
        unsafe:
            let locales = ptr[ptr[c.SDL_Locale]?]<-locales_memory
            let msg = cstr<-raw(addr(msgbuf[0]))

            c.SDL_snprintf(raw(addr(msgbuf[0])), 128, c"Locales, in order of preference (%d total):", count)

            let header_x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(msg))) / 2.0)
            c.SDL_RenderDebugText(renderer, header_x, frame.y, msg)

            var index: i32 = 0
            while true:
                let locale = deref(locales + index)
                if locale == null:
                    break

                let country_ptr = ptr[char]?<-locale.country
                let separator = if country_ptr != null then c"_" else c""
                let country = if country_ptr != null then cstr<-country_ptr else c""

                c.SDL_snprintf(raw(addr(msgbuf[0])), 128, c" - %s%s%s", locale.language, separator, country)

                let x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(msg))) / 2.0)
                let y = frame.y + (f32<-(c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * 2) * f32<-(index + 1))
                c.SDL_RenderDebugText(renderer, x, y, msg)

                index += 1

            c.SDL_free(ptr[void]<-locales_memory)

    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Misc Locale", c"1.0", c"com.example.misc-locale")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
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
