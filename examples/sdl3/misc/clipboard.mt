import std.sdl3 as sdl
import std.sdl3.runtime as runtime
import std.str as text_ops

const WINDOW_WIDTH: int = 640
const WINDOW_HEIGHT: int = 480

var currenttimerect: sdl.FRect
var copybuttonrect: sdl.FRect
var pastetextrect: sdl.FRect
var pastebuttonrect: sdl.FRect
var copy_pressed: bool = false
var paste_pressed: bool = false
var current_time: str_buffer[64]
var pasted_str: ptr[char]? = null


function calculate_current_time_string() -> void:
    var ticks: sdl.Time = 0
    var dt: sdl.DateTime = zero[sdl.DateTime]
    if not sdl.get_current_time(ticks) or not sdl.time_to_date_time(ticks, dt, true):
        current_time.assign("(Don't know the current time, sorry.)")
    else:
        let months = array[str, 12](
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        )
        let days = array[str, 7](
            "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
        )
        current_time.assign_format(f"#{days[dt.day_of_week]}, #{months[dt.month - 1]} #{dt.day}, #{dt.year}   ")
        if dt.hour < 10:
            current_time.append("0")
        current_time.append_format(f"#{dt.hour}")
        current_time.append(":")
        if dt.minute < 10:
            current_time.append("0")
        current_time.append_format(f"#{dt.minute}")
        current_time.append(":")
        if dt.second < 10:
            current_time.append("0")
        current_time.append_format(f"#{dt.second}")


function point_in_rect_float(point: sdl.FPoint, rect: sdl.FRect) -> bool:
    return (
        point.x >= rect.x
        and point.x < rect.x + rect.w
        and point.y >= rect.y
        and point.y < rect.y + rect.h
    )


function render_pasted_text(renderer: sdl.Renderer) -> void:
    if pasted_str == null:
        return
    let pasted = text_ops.chars_as_str(pasted_str)
    let text_x = pastetextrect.x + 5
    let text_y = pastetextrect.y + 5
    let max_chars = int<-(pastetextrect.w - 10) / sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE
    var y = text_y
    var remaining = pasted
    var more_lines = true
    while more_lines:
        var line = remaining
        let newline = remaining.find_substring("\n")
        if newline.is_some():
            let idx = newline.unwrap()
            line = remaining.slice(0, idx)
            remaining = remaining.slice(idx + 1, remaining.len - (idx + 1))
        else:
            more_lines = false
        if line.len > 0 and line.byte_at(line.len - 1) == 13:
            line = line.slice(0, line.len - 1)
        let visible = if line.len > ptr_uint<-max_chars: line.slice(0, ptr_uint<-max_chars) else: line
        sdl.render_debug_text(renderer, text_x, y, visible)
        y += sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE + 2
        if (pastetextrect.h - (y - text_y)) < sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE:
            break


function main() -> int:
    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/misc/clipboard",
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
    defer:
        if pasted_str != null:
            sdl.free(unsafe: ptr[void]<-pasted_str)

    calculate_current_time_string()

    currenttimerect.x = 30
    currenttimerect.y = 10
    currenttimerect.w = 390
    currenttimerect.h = sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE + 10

    copybuttonrect.x = currenttimerect.x + currenttimerect.w + 30
    copybuttonrect.y = currenttimerect.y
    copybuttonrect.w = runtime.debug_text_width("Click here to copy!") + 10
    copybuttonrect.h = currenttimerect.h

    pastetextrect.x = 10
    pastetextrect.y = currenttimerect.y + currenttimerect.h + 10
    pastetextrect.w = 620
    pastetextrect.h = (WINDOW_HEIGHT - pastetextrect.y) - copybuttonrect.h - 20

    pastebuttonrect.w = runtime.debug_text_width("Click here to paste!") + 10
    pastebuttonrect.x = (WINDOW_WIDTH - pastebuttonrect.w) / 2.0
    pastebuttonrect.y = pastetextrect.y + pastetextrect.h + 10
    pastebuttonrect.h = copybuttonrect.h

    var running = true
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            sdl.convert_event_to_render_coordinates(renderer, ev)
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
                if ev.button.button == sdl.BUTTON_LEFT:
                    let point = sdl.FPoint(x = ev.button.x, y = ev.button.y)
                    copy_pressed = point_in_rect_float(point, copybuttonrect)
                    paste_pressed = point_in_rect_float(point, pastebuttonrect)
            else if ev_type == int<-sdl.EventType.SDL_EVENT_MOUSE_BUTTON_UP:
                if ev.button.button == sdl.BUTTON_LEFT:
                    let point = sdl.FPoint(x = ev.button.x, y = ev.button.y)
                    if copy_pressed and point_in_rect_float(point, copybuttonrect):
                        sdl.set_clipboard_text(current_time.as_str())
                    else if paste_pressed and point_in_rect_float(point, pastebuttonrect):
                        if pasted_str != null:
                            sdl.free(unsafe: ptr[void]<-pasted_str)
                        pasted_str = sdl.get_clipboard_text()
                    copy_pressed = false
                    paste_pressed = false

        calculate_current_time_string()

        sdl.set_render_draw_color(renderer, 0, 0, 0, 255)
        sdl.render_clear(renderer)

        sdl.set_render_draw_color(renderer, 0, 0, 255, 255)
        sdl.render_fill_rect(renderer, currenttimerect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_rect(renderer, currenttimerect)

        let time_str = current_time.as_str()
        let time_x = currenttimerect.x + (currenttimerect.w - runtime.debug_text_width(time_str)) / 2.0
        let time_y = currenttimerect.y + 5
        sdl.set_render_draw_color(renderer, 255, 255, 0, 255)
        sdl.render_debug_text(renderer, time_x, time_y, time_str)

        if copy_pressed:
            sdl.set_render_draw_color(renderer, 0, 255, 0, 255)
        else:
            sdl.set_render_draw_color(renderer, 255, 0, 0, 255)
        sdl.render_fill_rect(renderer, copybuttonrect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_rect(renderer, copybuttonrect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_debug_text(renderer, copybuttonrect.x + 5, copybuttonrect.y + 5, "Click here to copy!")

        sdl.set_render_draw_color(renderer, 0, 53, 25, 255)
        sdl.render_fill_rect(renderer, pastetextrect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_rect(renderer, pastetextrect)

        sdl.set_render_draw_color(renderer, 0, 219, 107, 255)
        render_pasted_text(renderer)

        if paste_pressed:
            sdl.set_render_draw_color(renderer, 0, 255, 0, 255)
        else:
            sdl.set_render_draw_color(renderer, 255, 0, 0, 255)
        sdl.render_fill_rect(renderer, pastebuttonrect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_rect(renderer, pastebuttonrect)
        sdl.set_render_draw_color(renderer, 255, 255, 255, 255)
        sdl.render_debug_text(renderer, pastebuttonrect.x + 5, pastebuttonrect.y + 5, "Click here to paste!")

        sdl.render_present(renderer)

    return 0
