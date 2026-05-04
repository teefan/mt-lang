module examples.sdl3.misc.clipboard

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/misc/clipboard"
const window_flags: u64 = u64<-c.SDL_WINDOW_RESIZABLE
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_LETTERBOX
const copy_button_text: cstr = c"Click here to copy!"
const paste_button_text: cstr = c"Click here to paste!"
const unknown_time_text: cstr = c"(Don't know the current time, sorry.)"

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var current_time_rect: c.SDL_FRect = zero[c.SDL_FRect]
var copy_button_rect: c.SDL_FRect = zero[c.SDL_FRect]
var paste_text_rect: c.SDL_FRect = zero[c.SDL_FRect]
var paste_button_rect: c.SDL_FRect = zero[c.SDL_FRect]
var copy_pressed: bool = false
var paste_pressed: bool = false
var current_time: array[char, 64] = zero[array[char, 64]]
var pasted_str: ptr[char]? = null


def text_width(text: cstr) -> f32:
    return f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE * f32<-c.SDL_strlen(text)


def min_usize(left: usize, right: usize) -> usize:
    if left < right:
        return left

    return right


def point_in_rect(point: c.SDL_FPoint, rect: c.SDL_FRect) -> bool:
    return point.x >= rect.x and point.x < (rect.x + rect.w) and point.y >= rect.y and point.y < (rect.y + rect.h)


def current_time_text() -> cstr:
    unsafe:
        return cstr<-ptr_of(current_time[0])


def calculate_current_time_string() -> void:
    let month_names = array[cstr, 12](
        c"January",
        c"February",
        c"March",
        c"April",
        c"May",
        c"June",
        c"July",
        c"August",
        c"September",
        c"October",
        c"November",
        c"December",
    )
    let day_names = array[cstr, 7](c"Sunday", c"Monday", c"Tuesday", c"Wednesday", c"Thursday", c"Friday", c"Saturday")
    var ticks: c.SDL_Time = 0
    var dt = zero[c.SDL_DateTime]

    if not c.SDL_GetCurrentTime(ptr_of(ticks)) or not c.SDL_TimeToDateTime(ticks, ptr_of(dt), true):
        c.SDL_snprintf(ptr_of(current_time[0]), 64, c"%s", unknown_time_text)
    else:
        c.SDL_snprintf(
            ptr_of(current_time[0]),
            64,
            c"%s, %s %d, %d   %02d:%02d:%02d",
            day_names[dt.day_of_week],
            month_names[dt.month - 1],
            dt.day,
            dt.year,
            dt.hour,
            dt.minute,
            dt.second,
        )


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        c.SDL_ConvertEventToRenderCoordinates(renderer, ptr_of(event))

        if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
                if event.button.button == c.Uint8<-c.SDL_BUTTON_LEFT:
                    let point = c.SDL_FPoint(x = event.button.x, y = event.button.y)
                    copy_pressed = point_in_rect(point, copy_button_rect)
                    paste_pressed = point_in_rect(point, paste_button_rect)
            else:
                if event.type_ == u32<-c.SDL_EventType.SDL_EVENT_MOUSE_BUTTON_UP:
                    if event.button.button == c.Uint8<-c.SDL_BUTTON_LEFT:
                        let point = c.SDL_FPoint(x = event.button.x, y = event.button.y)

                        if copy_pressed and point_in_rect(point, copy_button_rect):
                            c.SDL_SetClipboardText(current_time_text())
                        else:
                            if paste_pressed and point_in_rect(point, paste_button_rect):
                                if pasted_str != null:
                                    unsafe:
                                        c.SDL_free(ptr[void]<-pasted_str)

                                pasted_str = c.SDL_GetClipboardText()

                        copy_pressed = false
                        paste_pressed = false

    return true


def render_truncated_line(text: ptr[char], x: f32, y: f32, max_chars_per_line: usize) -> void:
    unsafe:
        let line_length = min_usize(c.SDL_strlen(cstr<-text), max_chars_per_line)
        let end_ptr = ptr[char]<-(text + i32<-line_length)
        let saved_char = read(end_ptr)
        read(end_ptr) = char<-0
        c.SDL_RenderDebugText(renderer, x, y, cstr<-text)
        read(end_ptr) = saved_char


def render_pasted_text() -> void:
    let initial_text = pasted_str
    if initial_text == null:
        return

    let x = paste_text_rect.x + 5.0
    var y = paste_text_rect.y + 5.0
    let w = paste_text_rect.w - 10.0
    let h = paste_text_rect.h
    let line_height = f32<-(c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE + 2)
    let max_chars_per_line = usize<-(w / f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)
    var text_ptr: ptr[char]? = initial_text

    while true:
        let line = text_ptr
        if line == null:
            break

        var newline: ptr[char]? = null
        unsafe:
            newline = c.SDL_strchr(cstr<-line, 10)
        if newline == null:
            break

        var ignore_cr = false

        unsafe:
            let line_end = ptr[char]<-newline

            if line_end != line and read(line_end - 1) == char<-13:
                ignore_cr = true
                read(line_end - 1) = char<-0

            read(line_end) = char<-0

        render_truncated_line(line, x, y, max_chars_per_line)

        unsafe:
            let line_end = ptr[char]<-newline

            if ignore_cr:
                read(line_end - 1) = char<-13
            read(line_end) = char<-10
            text_ptr = line_end + 1

        y += line_height

        if (h - y) < f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE:
            return

    let final_line = text_ptr
    if final_line != null and (h - y) >= f32<-c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE:
        render_truncated_line(final_line, x, y, max_chars_per_line)


def render_frame() -> void:
    calculate_current_time_string()

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderFillRect(renderer, ptr_of(current_time_rect))
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderRect(renderer, ptr_of(current_time_rect))

    let current_time_x = current_time_rect.x + ((current_time_rect.w - text_width(current_time_text())) / 2.0)
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, current_time_x, current_time_rect.y + 5.0, current_time_text())

    if copy_pressed:
        c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, c.SDL_ALPHA_OPAQUE)
    else:
        c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderFillRect(renderer, ptr_of(copy_button_rect))
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderRect(renderer, ptr_of(copy_button_rect))
    c.SDL_RenderDebugText(renderer, copy_button_rect.x + 5.0, copy_button_rect.y + 5.0, copy_button_text)

    c.SDL_SetRenderDrawColor(renderer, 0, 53, 25, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderFillRect(renderer, ptr_of(paste_text_rect))
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderRect(renderer, ptr_of(paste_text_rect))

    c.SDL_SetRenderDrawColor(renderer, 0, 219, 107, c.SDL_ALPHA_OPAQUE)
    render_pasted_text()

    if paste_pressed:
        c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, c.SDL_ALPHA_OPAQUE)
    else:
        c.SDL_SetRenderDrawColor(renderer, 255, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderFillRect(renderer, ptr_of(paste_button_rect))
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderRect(renderer, ptr_of(paste_button_rect))
    c.SDL_RenderDebugText(renderer, paste_button_rect.x + 5.0, paste_button_rect.y + 5.0, paste_button_text)

    c.SDL_RenderPresent(renderer)


def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Misc Clipboard", c"1.0", c"com.example.misc-clipboard")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)
    defer:
        if pasted_str != null:
            unsafe:
                c.SDL_free(ptr[void]<-pasted_str)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    calculate_current_time_string()

    current_time_rect.x = 30.0
    current_time_rect.y = 10.0
    current_time_rect.w = 390.0
    current_time_rect.h = f32<-(c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE + 10)

    copy_button_rect.x = current_time_rect.x + current_time_rect.w + 30.0
    copy_button_rect.y = current_time_rect.y
    copy_button_rect.w = text_width(copy_button_text) + 10.0
    copy_button_rect.h = current_time_rect.h

    paste_text_rect.x = 10.0
    paste_text_rect.y = current_time_rect.y + current_time_rect.h + 10.0
    paste_text_rect.w = 620.0
    paste_text_rect.h = (480.0 - paste_text_rect.y) - copy_button_rect.h - 20.0

    paste_button_rect.w = text_width(paste_button_text) + 10.0
    paste_button_rect.x = (640.0 - paste_button_rect.w) / 2.0
    paste_button_rect.y = paste_text_rect.y + paste_text_rect.h + 10.0
    paste_button_rect.h = copy_button_rect.h

    while pump_events():
        render_frame()

    return 0


def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
