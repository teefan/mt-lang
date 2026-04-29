module examples.sdl3.input.gamepad_polling

import std.c.sdl3 as c

const window_width: i32 = 640
const window_height: i32 = 480
const window_title: cstr = c"examples/input/gamepad-polling"
const window_flags: u64 = cast[u64](c.SDL_WINDOW_RESIZABLE)
const presentation_mode: c.SDL_RendererLogicalPresentation = c.SDL_RendererLogicalPresentation.SDL_LOGICAL_PRESENTATION_STRETCH
const gamepad_texture_path: cstr = c"../resources/gamepad_front.png"
const button_rect_count: i32 = 16
const thumbbox_size: f32 = 30.0
const trigger_height: f32 = 65.0

var button_rects: array[c.SDL_FRect, 16] = array[c.SDL_FRect, 16](
    c.SDL_FRect(x = 497.0, y = 266.0, w = 38.0, h = 38.0),
    c.SDL_FRect(x = 550.0, y = 217.0, w = 38.0, h = 38.0),
    c.SDL_FRect(x = 445.0, y = 221.0, w = 38.0, h = 38.0),
    c.SDL_FRect(x = 499.0, y = 173.0, w = 38.0, h = 38.0),
    c.SDL_FRect(x = 235.0, y = 228.0, w = 32.0, h = 29.0),
    c.SDL_FRect(x = 287.0, y = 195.0, w = 69.0, h = 69.0),
    c.SDL_FRect(x = 377.0, y = 228.0, w = 32.0, h = 29.0),
    c.SDL_FRect(x = 91.0, y = 234.0, w = 63.0, h = 63.0),
    c.SDL_FRect(x = 381.0, y = 354.0, w = 63.0, h = 63.0),
    c.SDL_FRect(x = 74.0, y = 73.0, w = 102.0, h = 29.0),
    c.SDL_FRect(x = 468.0, y = 73.0, w = 102.0, h = 29.0),
    c.SDL_FRect(x = 207.0, y = 316.0, w = 32.0, h = 32.0),
    c.SDL_FRect(x = 207.0, y = 384.0, w = 32.0, h = 32.0),
    c.SDL_FRect(x = 173.0, y = 351.0, w = 32.0, h = 32.0),
    c.SDL_FRect(x = 242.0, y = 351.0, w = 32.0, h = 32.0),
    c.SDL_FRect(x = 310.0, y = 286.0, w = 23.0, h = 27.0),
)

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var texture: ptr[c.SDL_Texture]
var gamepad: ptr[c.SDL_Gamepad]? = null
var left_thumb_last: c.Uint64 = 0
var right_thumb_last: c.Uint64 = 0

def pump_events() -> bool:
    var event = c.SDL_Event(type = 0)

    while c.SDL_PollEvent(raw(addr(event))):
        if event.quit.type == c.SDL_EventType.SDL_EVENT_QUIT:
            return false
        else:
            if event.gdevice.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_ADDED:
                if gamepad == null:
                    gamepad = c.SDL_OpenGamepad(event.gdevice.which)
            else:
                if event.gdevice.type == c.SDL_EventType.SDL_EVENT_GAMEPAD_REMOVED:
                    if gamepad != null:
                        if c.SDL_GetGamepadID(gamepad) == event.gdevice.which:
                            c.SDL_CloseGamepad(gamepad)
                            gamepad = null

    return true

def thumbbox_x(origin: f32, axis_x: c.Sint16) -> f32:
    return origin + ((cast[f32](axis_x) / 32767.0) * thumbbox_size)

def thumbbox_y(origin: f32, axis_y: c.Sint16) -> f32:
    return origin + ((cast[f32](axis_y) / 32767.0) * thumbbox_size)

def axis_active(axis_x: c.Sint16, axis_y: c.Sint16) -> bool:
    return c.SDL_abs(cast[i32](axis_x)) > 1000 or c.SDL_abs(cast[i32](axis_y)) > 1000

def trigger_box(x: f32, axis_y: c.Sint16) -> c.SDL_FRect:
    let height = (cast[f32](axis_y) / 32767.0) * trigger_height
    return c.SDL_FRect(x = x, y = 1.0 + (trigger_height - height), w = 37.0, h = height)

def render_frame() -> void:
    var text: cstr = c"Plug in a gamepad, please."
    var x: f32 = 0.0
    var y: f32 = 0.0
    let now = c.SDL_GetTicks()

    if gamepad != null:
        text = c.SDL_GetGamepadName(gamepad)

    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    if gamepad != null:
        c.SDL_RenderTexture(renderer, texture, null, null)

        c.SDL_SetRenderDrawColor(renderer, 0, 255, 0, c.SDL_ALPHA_OPAQUE)
        for index in range(0, button_rect_count):
            if c.SDL_GetGamepadButton(gamepad, cast[c.SDL_GamepadButton](index)):
                c.SDL_RenderFillRect(renderer, raw(addr(button_rects[index])))

        c.SDL_SetRenderDrawColor(renderer, 255, 255, 0, c.SDL_ALPHA_OPAQUE)

        var axis_x = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTX)
        var axis_y = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFTY)
        if axis_active(axis_x, axis_y):
            left_thumb_last = now
        if now - left_thumb_last < 500:
            var left_box = c.SDL_FRect(x = thumbbox_x(107.0, axis_x), y = thumbbox_y(252.0, axis_y), w = thumbbox_size, h = thumbbox_size)
            c.SDL_RenderFillRect(renderer, raw(addr(left_box)))

        axis_x = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTX)
        axis_y = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHTY)
        if axis_active(axis_x, axis_y):
            right_thumb_last = now
        if now - right_thumb_last < 500:
            var right_box = c.SDL_FRect(x = thumbbox_x(397.0, axis_x), y = thumbbox_y(370.0, axis_y), w = thumbbox_size, h = thumbbox_size)
            c.SDL_RenderFillRect(renderer, raw(addr(right_box)))

        axis_y = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_LEFT_TRIGGER)
        if cast[i32](axis_y) > 1000:
            var left_trigger = trigger_box(127.0, axis_y)
            c.SDL_RenderFillRect(renderer, raw(addr(left_trigger)))

        axis_y = c.SDL_GetGamepadAxis(gamepad, c.SDL_GamepadAxis.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)
        if cast[i32](axis_y) > 1000:
            var right_trigger = trigger_box(481.0, axis_y)
            c.SDL_RenderFillRect(renderer, raw(addr(right_trigger)))

    let text_width = cast[f32](c.SDL_strlen(text) * cast[usize](c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE))
    x = (cast[f32](window_width) - text_width) / 2.0
    if gamepad != null:
        y = cast[f32](window_height - (c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE + 2))
    else:
        y = (cast[f32](window_height) - cast[f32](c.SDL_DEBUG_TEXT_FONT_CHARACTER_SIZE)) / 2.0

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugText(renderer, x, y, text)
    c.SDL_RenderPresent(renderer)

def app_main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    c.SDL_SetAppMetadata(c"Example Input Gamepad Polling", c"1.0", c"com.example.input-gamepad-polling")

    if not c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMEPAD):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, raw(addr(window)), raw(addr(renderer))):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    if not c.SDL_SetRenderLogicalPresentation(renderer, window_width, window_height, presentation_mode):
        return 1

    let surface = c.SDL_LoadPNG(gamepad_texture_path)
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

    if gamepad != null:
        c.SDL_CloseGamepad(gamepad)

    return 0

def main(argc: i32, argv: ptr[ptr[char]]) -> i32:
    return c.SDL_RunApp(argc, argv, app_main, null)
