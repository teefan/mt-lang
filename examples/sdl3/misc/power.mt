module examples.sdl3.misc.power

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/misc/power"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const unknown_time_text: cstr = c"unknown time"
const battery_format: cstr = c"Battery: %3d percent, %s remaining"

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]


def pump_events() -> bool:
    var event = zero[c.SDL_Event]()

    while c.SDL_PollEvent(ptr_of(ref_of(event))):
        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

    return true


def render_frame() -> void:
    var frame = c.SDL_FRect(x = 100.0, y = 200.0, w = 440.0, h = 80.0)
    var seconds: i32 = 0
    var percent: i32 = 0
    let state = c.SDL_GetPowerInfo(ptr_of(ref_of(seconds)), ptr_of(ref_of(percent)))

    var clear_r: c.Uint8 = 0
    var clear_g: c.Uint8 = 0
    var clear_b: c.Uint8 = 0
    var text_r: c.Uint8 = 255
    var text_g: c.Uint8 = 255
    var text_b: c.Uint8 = 255
    var frame_r: c.Uint8 = 255
    var frame_g: c.Uint8 = 255
    var frame_b: c.Uint8 = 255
    var bar_r: c.Uint8 = 0
    var bar_g: c.Uint8 = 0
    var bar_b: c.Uint8 = 0
    var msg: cstr = c""
    var msg2: cstr = c""
    var has_msg = false
    var has_msg2 = false

    if state == c.SDL_PowerState.SDL_POWERSTATE_ERROR:
        msg2 = c"ERROR GETTING POWER STATE"
        msg = c.SDL_GetError()
        has_msg = true
        has_msg2 = true
        clear_r = 255
    else:
        if state == c.SDL_PowerState.SDL_POWERSTATE_UNKNOWN:
            msg = c"Power state is unknown."
            has_msg = true
            clear_r = 50
            clear_g = 50
            clear_b = 50
        else:
            if state == c.SDL_PowerState.SDL_POWERSTATE_ON_BATTERY:
                msg = c"Running on battery."
                has_msg = true
                bar_r = 255
            else:
                if state == c.SDL_PowerState.SDL_POWERSTATE_NO_BATTERY:
                    msg = c"Plugged in, no battery available."
                    has_msg = true
                    clear_g = 50
                else:
                    if state == c.SDL_PowerState.SDL_POWERSTATE_CHARGING:
                        msg = c"Charging."
                        has_msg = true
                        bar_g = 255
                        bar_b = 255
                    else:
                        msg = c"Charged."
                        has_msg = true
                        bar_g = 255

    c.SDL_SetRenderDrawColor(renderer, clear_r, clear_g, clear_b, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    if percent >= 0:
        var pct_rect = frame
        var remainstr = zero[array[char, 64]]()
        var msgbuf = zero[array[char, 128]]()
        var x: f32 = 0.0
        var y: f32 = 0.0

        unsafe:
            let remainstr_ptr = cstr<-ptr_of(ref_of(remainstr[0]))
            let msgbuf_ptr = cstr<-ptr_of(ref_of(msgbuf[0]))

            pct_rect.w *= f32<-percent / 100.0

            if seconds < 0:
                c.SDL_strlcpy(ptr_of(ref_of(remainstr[0])), unknown_time_text, 64)
            else:
                let hours = seconds / (60 * 60)
                seconds -= hours * (60 * 60)
                let minutes = seconds / 60
                seconds -= minutes * 60
                c.SDL_snprintf(ptr_of(ref_of(remainstr[0])), 64, c"%02d:%02d:%02d", hours, minutes, seconds)

            c.SDL_snprintf(ptr_of(ref_of(msgbuf[0])), 128, battery_format, percent, remainstr_ptr)
            x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(msgbuf_ptr))) / 2.0)
            y = frame.y + frame.h + f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE

        c.SDL_SetRenderDrawColor(renderer, bar_r, bar_g, bar_b, c.SDL_ALPHA_OPAQUE)
        c.SDL_RenderFillRect(renderer, ptr_of(ref_of(pct_rect)))
        c.SDL_SetRenderDrawColor(renderer, frame_r, frame_g, frame_b, c.SDL_ALPHA_OPAQUE)
        c.SDL_RenderRect(renderer, ptr_of(ref_of(frame)))
        c.SDL_SetRenderDrawColor(renderer, text_r, text_g, text_b, c.SDL_ALPHA_OPAQUE)
        unsafe:
            c.SDL_RenderDebugText(renderer, x, y, cstr<-ptr_of(ref_of(msgbuf[0])))

    if has_msg:
        let x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(msg))) / 2.0)
        let y = frame.y - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * 2.0)
        c.SDL_SetRenderDrawColor(renderer, text_r, text_g, text_b, c.SDL_ALPHA_OPAQUE)
        c.SDL_RenderDebugText(renderer, x, y, msg)

    if has_msg2:
        let x = frame.x + ((frame.w - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(msg2))) / 2.0)
        let y = frame.y - (f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * 4.0)
        c.SDL_SetRenderDrawColor(renderer, text_r, text_g, text_b, c.SDL_ALPHA_OPAQUE)
        c.SDL_RenderDebugText(renderer, x, y, msg2)

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Misc Power", c"1.0", c"com.example.misc-power")

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
