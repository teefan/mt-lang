import std.sdl3 as sdl
import std.sdl3.runtime as runtime
import std.str as text_ops

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/misc/power",
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    if not sdl.set_render_logical_presentation(
        renderer,
        WINDOW_WIDTH,
        WINDOW_HEIGHT,
        sdl.RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
    ):
        pass

    let frame = sdl.FRect(x = 100, y = 200, w = 440, h = 80)

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            if ev.type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false

        var seconds: int = 0
        var percent: int = 0
        let state = sdl.get_power_info(seconds, percent)

        var clear_r: int = 0
        var clear_g: int = 0
        var clear_b: int = 0
        let text_r = 255
        let text_g = 255
        let text_b = 255
        let frame_r = 255
        let frame_g = 255
        let frame_b = 255
        var bar_r: int = 0
        var bar_g: int = 0
        var bar_b: int = 0
        var msg: cstr? = null
        var msg2: cstr? = null

        match state:
            sdl.PowerState.SDL_POWERSTATE_ERROR:
                msg2 = c"ERROR GETTING POWER STATE"
                msg = sdl.get_error()
                clear_r = 255
            sdl.PowerState.SDL_POWERSTATE_UNKNOWN:
                msg = c"Power state is unknown."
                clear_r = 50
                clear_g = 50
                clear_b = 50
            sdl.PowerState.SDL_POWERSTATE_ON_BATTERY:
                msg = c"Running on battery."
                bar_r = 255
            sdl.PowerState.SDL_POWERSTATE_NO_BATTERY:
                msg = c"Plugged in, no battery available."
                clear_g = 50
            sdl.PowerState.SDL_POWERSTATE_CHARGING:
                msg = c"Charging."
                bar_b = 255
                bar_g = 255
            sdl.PowerState.SDL_POWERSTATE_CHARGED:
                msg = c"Charged."
                bar_g = 255
            _:
                msg = c"Power state is unknown."
                clear_r = 50
                clear_g = 50
                clear_b = 50

        sdl.set_render_draw_color(renderer, ubyte<-clear_r, ubyte<-clear_g, ubyte<-clear_b, 255)
        sdl.render_clear(renderer)

        if percent >= 0:
            var pctrect = frame
            pctrect.w *= percent / 100.0

            var remain: str_buffer[64]
            if seconds < 0:
                remain.assign("unknown time")
            else:
                let hours = seconds / 3600
                let rem = seconds - hours * 3600
                let minutes = rem / 60
                let secs = rem - minutes * 60
                if hours < 10:
                    remain.append("0")
                remain.append_format(f"#{hours}")
                remain.append(":")
                if minutes < 10:
                    remain.append("0")
                remain.append_format(f"#{minutes}")
                remain.append(":")
                if secs < 10:
                    remain.append("0")
                remain.append_format(f"#{secs}")

            var msgbuf: str_buffer[128]
            msgbuf.assign_format(f"Battery: #{percent} percent, #{remain.as_str()} remaining")

            sdl.set_render_draw_color(renderer, ubyte<-bar_r, ubyte<-bar_g, ubyte<-bar_b, 255)
            sdl.render_fill_rect(renderer, pctrect)
            sdl.set_render_draw_color(renderer, ubyte<-frame_r, ubyte<-frame_g, ubyte<-frame_b, 255)
            sdl.render_rect(renderer, frame)
            sdl.set_render_draw_color(renderer, ubyte<-text_r, ubyte<-text_g, ubyte<-text_b, 255)

            let msgbuf_str = msgbuf.as_str()
            let msg_x = frame.x + (frame.w - runtime.debug_text_width(msgbuf_str)) / 2.0
            let msg_y = frame.y + frame.h + sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
            sdl.render_debug_text(renderer, msg_x, msg_y, msgbuf_str)

        if msg != null:
            let msg_str = text_ops.cstr_as_str(msg)
            let msg_x = frame.x + (frame.w - runtime.debug_text_width(msg_str)) / 2.0
            let msg_y = frame.y - sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE * 2
            sdl.set_render_draw_color(renderer, ubyte<-text_r, ubyte<-text_g, ubyte<-text_b, 255)
            sdl.render_debug_text(renderer, msg_x, msg_y, msg_str)

        if msg2 != null:
            let msg_str = text_ops.cstr_as_str(msg2)
            let msg_x = frame.x + (frame.w - runtime.debug_text_width(msg_str)) / 2.0
            let msg_y = frame.y - sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE * 4
            sdl.set_render_draw_color(renderer, ubyte<-text_r, ubyte<-text_g, ubyte<-text_b, 255)
            sdl.render_debug_text(renderer, msg_x, msg_y, msg_str)

        sdl.render_present(renderer)

    return 0
