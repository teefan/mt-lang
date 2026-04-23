module examples.raylib.core.core_keyboard_testbed

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const key_rec_spacing: i32 = 4
const window_title: cstr = c"raylib [core] example - keyboard testbed"
const keyboard_layout_text: cstr = c"KEYBOARD LAYOUT: ENG-US"

def key_text(key: i32) -> cstr:
    if key == rl.KeyboardKey.KEY_APOSTROPHE:
        return c"'"
    if key == rl.KeyboardKey.KEY_COMMA:
        return c","
    if key == rl.KeyboardKey.KEY_MINUS:
        return c"-"
    if key == rl.KeyboardKey.KEY_PERIOD:
        return c"."
    if key == rl.KeyboardKey.KEY_SLASH:
        return c"/"
    if key == rl.KeyboardKey.KEY_ZERO:
        return c"0"
    if key == rl.KeyboardKey.KEY_ONE:
        return c"1"
    if key == rl.KeyboardKey.KEY_TWO:
        return c"2"
    if key == rl.KeyboardKey.KEY_THREE:
        return c"3"
    if key == rl.KeyboardKey.KEY_FOUR:
        return c"4"
    if key == rl.KeyboardKey.KEY_FIVE:
        return c"5"
    if key == rl.KeyboardKey.KEY_SIX:
        return c"6"
    if key == rl.KeyboardKey.KEY_SEVEN:
        return c"7"
    if key == rl.KeyboardKey.KEY_EIGHT:
        return c"8"
    if key == rl.KeyboardKey.KEY_NINE:
        return c"9"
    if key == rl.KeyboardKey.KEY_SEMICOLON:
        return c";"
    if key == rl.KeyboardKey.KEY_EQUAL:
        return c"="
    if key == rl.KeyboardKey.KEY_A:
        return c"A"
    if key == rl.KeyboardKey.KEY_B:
        return c"B"
    if key == rl.KeyboardKey.KEY_C:
        return c"C"
    if key == rl.KeyboardKey.KEY_D:
        return c"D"
    if key == rl.KeyboardKey.KEY_E:
        return c"E"
    if key == rl.KeyboardKey.KEY_F:
        return c"F"
    if key == rl.KeyboardKey.KEY_G:
        return c"G"
    if key == rl.KeyboardKey.KEY_H:
        return c"H"
    if key == rl.KeyboardKey.KEY_I:
        return c"I"
    if key == rl.KeyboardKey.KEY_J:
        return c"J"
    if key == rl.KeyboardKey.KEY_K:
        return c"K"
    if key == rl.KeyboardKey.KEY_L:
        return c"L"
    if key == rl.KeyboardKey.KEY_M:
        return c"M"
    if key == rl.KeyboardKey.KEY_N:
        return c"N"
    if key == rl.KeyboardKey.KEY_O:
        return c"O"
    if key == rl.KeyboardKey.KEY_P:
        return c"P"
    if key == rl.KeyboardKey.KEY_Q:
        return c"Q"
    if key == rl.KeyboardKey.KEY_R:
        return c"R"
    if key == rl.KeyboardKey.KEY_S:
        return c"S"
    if key == rl.KeyboardKey.KEY_T:
        return c"T"
    if key == rl.KeyboardKey.KEY_U:
        return c"U"
    if key == rl.KeyboardKey.KEY_V:
        return c"V"
    if key == rl.KeyboardKey.KEY_W:
        return c"W"
    if key == rl.KeyboardKey.KEY_X:
        return c"X"
    if key == rl.KeyboardKey.KEY_Y:
        return c"Y"
    if key == rl.KeyboardKey.KEY_Z:
        return c"Z"
    if key == rl.KeyboardKey.KEY_LEFT_BRACKET:
        return c"["
    if key == rl.KeyboardKey.KEY_BACKSLASH:
        return c"BSLASH"
    if key == rl.KeyboardKey.KEY_RIGHT_BRACKET:
        return c"]"
    if key == rl.KeyboardKey.KEY_GRAVE:
        return c"`"
    if key == rl.KeyboardKey.KEY_SPACE:
        return c"SPACE"
    if key == rl.KeyboardKey.KEY_ESCAPE:
        return c"ESC"
    if key == rl.KeyboardKey.KEY_ENTER:
        return c"ENTER"
    if key == rl.KeyboardKey.KEY_TAB:
        return c"TAB"
    if key == rl.KeyboardKey.KEY_BACKSPACE:
        return c"BACK"
    if key == rl.KeyboardKey.KEY_INSERT:
        return c"INS"
    if key == rl.KeyboardKey.KEY_DELETE:
        return c"DEL"
    if key == rl.KeyboardKey.KEY_RIGHT:
        return c"RIGHT"
    if key == rl.KeyboardKey.KEY_LEFT:
        return c"LEFT"
    if key == rl.KeyboardKey.KEY_DOWN:
        return c"DOWN"
    if key == rl.KeyboardKey.KEY_UP:
        return c"UP"
    if key == rl.KeyboardKey.KEY_PAGE_UP:
        return c"PGUP"
    if key == rl.KeyboardKey.KEY_PAGE_DOWN:
        return c"PGDOWN"
    if key == rl.KeyboardKey.KEY_CAPS_LOCK:
        return c"CAPS"
    if key == rl.KeyboardKey.KEY_PRINT_SCREEN:
        return c"PRINTSCR"
    if key == rl.KeyboardKey.KEY_PAUSE:
        return c"PAUSE"
    if key == rl.KeyboardKey.KEY_F1:
        return c"F1"
    if key == rl.KeyboardKey.KEY_F2:
        return c"F2"
    if key == rl.KeyboardKey.KEY_F3:
        return c"F3"
    if key == rl.KeyboardKey.KEY_F4:
        return c"F4"
    if key == rl.KeyboardKey.KEY_F5:
        return c"F5"
    if key == rl.KeyboardKey.KEY_F6:
        return c"F6"
    if key == rl.KeyboardKey.KEY_F7:
        return c"F7"
    if key == rl.KeyboardKey.KEY_F8:
        return c"F8"
    if key == rl.KeyboardKey.KEY_F9:
        return c"F9"
    if key == rl.KeyboardKey.KEY_F10:
        return c"F10"
    if key == rl.KeyboardKey.KEY_F11:
        return c"F11"
    if key == rl.KeyboardKey.KEY_F12:
        return c"F12"
    if key == rl.KeyboardKey.KEY_LEFT_SHIFT:
        return c"LSHIFT"
    if key == rl.KeyboardKey.KEY_LEFT_CONTROL:
        return c"LCTRL"
    if key == rl.KeyboardKey.KEY_LEFT_ALT:
        return c"LALT"
    if key == rl.KeyboardKey.KEY_LEFT_SUPER:
        return c"WIN"
    if key == rl.KeyboardKey.KEY_RIGHT_SHIFT:
        return c"RSHIFT"
    if key == rl.KeyboardKey.KEY_RIGHT_CONTROL:
        return c"RCTRL"
    if key == rl.KeyboardKey.KEY_RIGHT_ALT:
        return c"ALTGR"
    return c""

def draw_keyboard_key(bounds: rl.Rectangle, key: i32) -> void:
    if key == rl.KeyboardKey.KEY_NULL:
        rl.DrawRectangleLinesEx(bounds, 2.0, rl.LIGHTGRAY)
    else:
        let active = rl.IsKeyDown(key)
        if active:
            rl.DrawRectangleLinesEx(bounds, 2.0, rl.MAROON)
            rl.DrawText(key_text(key), cast[i32](bounds.x) + 4, cast[i32](bounds.y) + 4, 10, rl.MAROON)
        else:
            rl.DrawRectangleLinesEx(bounds, 2.0, rl.DARKGRAY)
            rl.DrawText(key_text(key), cast[i32](bounds.x) + 4, cast[i32](bounds.y) + 4, 10, rl.DARKGRAY)

    if rl.CheckCollisionPointRec(rl.GetMousePosition(), bounds):
        rl.DrawRectangleRec(bounds, rl.Fade(rl.RED, 0.2))
        rl.DrawRectangleLinesEx(bounds, 3.0, rl.RED)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()
    rl.SetExitKey(rl.KeyboardKey.KEY_NULL)

    let line01_widths = array[i32, 15](45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 62, 45)
    let line01_keys = array[i32, 15](
        rl.KeyboardKey.KEY_ESCAPE, rl.KeyboardKey.KEY_F1, rl.KeyboardKey.KEY_F2,
        rl.KeyboardKey.KEY_F3, rl.KeyboardKey.KEY_F4, rl.KeyboardKey.KEY_F5,
        rl.KeyboardKey.KEY_F6, rl.KeyboardKey.KEY_F7, rl.KeyboardKey.KEY_F8,
        rl.KeyboardKey.KEY_F9, rl.KeyboardKey.KEY_F10, rl.KeyboardKey.KEY_F11,
        rl.KeyboardKey.KEY_F12, rl.KeyboardKey.KEY_PRINT_SCREEN, rl.KeyboardKey.KEY_PAUSE,
    )

    let line02_widths = array[i32, 15](25, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 82, 45)
    let line02_keys = array[i32, 15](
        rl.KeyboardKey.KEY_GRAVE, rl.KeyboardKey.KEY_ONE, rl.KeyboardKey.KEY_TWO,
        rl.KeyboardKey.KEY_THREE, rl.KeyboardKey.KEY_FOUR, rl.KeyboardKey.KEY_FIVE,
        rl.KeyboardKey.KEY_SIX, rl.KeyboardKey.KEY_SEVEN, rl.KeyboardKey.KEY_EIGHT,
        rl.KeyboardKey.KEY_NINE, rl.KeyboardKey.KEY_ZERO, rl.KeyboardKey.KEY_MINUS,
        rl.KeyboardKey.KEY_EQUAL, rl.KeyboardKey.KEY_BACKSPACE, rl.KeyboardKey.KEY_DELETE,
    )

    let line03_widths = array[i32, 15](50, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 57, 45)
    let line03_keys = array[i32, 15](
        rl.KeyboardKey.KEY_TAB, rl.KeyboardKey.KEY_Q, rl.KeyboardKey.KEY_W,
        rl.KeyboardKey.KEY_E, rl.KeyboardKey.KEY_R, rl.KeyboardKey.KEY_T,
        rl.KeyboardKey.KEY_Y, rl.KeyboardKey.KEY_U, rl.KeyboardKey.KEY_I,
        rl.KeyboardKey.KEY_O, rl.KeyboardKey.KEY_P, rl.KeyboardKey.KEY_LEFT_BRACKET,
        rl.KeyboardKey.KEY_RIGHT_BRACKET, rl.KeyboardKey.KEY_BACKSLASH, rl.KeyboardKey.KEY_INSERT,
    )

    let line04_widths = array[i32, 14](68, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 88, 45)
    let line04_keys = array[i32, 14](
        rl.KeyboardKey.KEY_CAPS_LOCK, rl.KeyboardKey.KEY_A, rl.KeyboardKey.KEY_S,
        rl.KeyboardKey.KEY_D, rl.KeyboardKey.KEY_F, rl.KeyboardKey.KEY_G,
        rl.KeyboardKey.KEY_H, rl.KeyboardKey.KEY_J, rl.KeyboardKey.KEY_K,
        rl.KeyboardKey.KEY_L, rl.KeyboardKey.KEY_SEMICOLON, rl.KeyboardKey.KEY_APOSTROPHE,
        rl.KeyboardKey.KEY_ENTER, rl.KeyboardKey.KEY_PAGE_UP,
    )

    let line05_widths = array[i32, 14](80, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 76, 45, 45)
    let line05_keys = array[i32, 14](
        rl.KeyboardKey.KEY_LEFT_SHIFT, rl.KeyboardKey.KEY_Z, rl.KeyboardKey.KEY_X,
        rl.KeyboardKey.KEY_C, rl.KeyboardKey.KEY_V, rl.KeyboardKey.KEY_B,
        rl.KeyboardKey.KEY_N, rl.KeyboardKey.KEY_M, rl.KeyboardKey.KEY_COMMA,
        rl.KeyboardKey.KEY_PERIOD, rl.KeyboardKey.KEY_SLASH, rl.KeyboardKey.KEY_RIGHT_SHIFT,
        rl.KeyboardKey.KEY_UP, rl.KeyboardKey.KEY_PAGE_DOWN,
    )

    let line06_widths = array[i32, 11](80, 45, 45, 208, 45, 45, 45, 60, 45, 45, 45)
    let line06_keys = array[i32, 11](
        rl.KeyboardKey.KEY_LEFT_CONTROL, rl.KeyboardKey.KEY_LEFT_SUPER, rl.KeyboardKey.KEY_LEFT_ALT,
        rl.KeyboardKey.KEY_SPACE, rl.KeyboardKey.KEY_RIGHT_ALT, 162,
        rl.KeyboardKey.KEY_NULL, rl.KeyboardKey.KEY_RIGHT_CONTROL, rl.KeyboardKey.KEY_LEFT,
        rl.KeyboardKey.KEY_DOWN, rl.KeyboardKey.KEY_RIGHT,
    )

    let keyboard_offset = rl.Vector2(x = 26.0, y = 80.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(keyboard_layout_text, 26, 38, 20, rl.LIGHTGRAY)

        var rec_offset_x = 0
        for index in range(0, 15):
            draw_keyboard_key(
                rl.Rectangle(x = keyboard_offset.x + rec_offset_x, y = keyboard_offset.y, width = line01_widths[index], height = 30.0),
                line01_keys[index],
            )
            rec_offset_x += line01_widths[index] + key_rec_spacing

        rec_offset_x = 0
        for index in range(0, 15):
            draw_keyboard_key(
                rl.Rectangle(
                    x = keyboard_offset.x + rec_offset_x,
                    y = keyboard_offset.y + 30.0 + key_rec_spacing,
                    width = line02_widths[index],
                    height = 38.0,
                ),
                line02_keys[index],
            )
            rec_offset_x += line02_widths[index] + key_rec_spacing

        rec_offset_x = 0
        for index in range(0, 15):
            draw_keyboard_key(
                rl.Rectangle(
                    x = keyboard_offset.x + rec_offset_x,
                    y = keyboard_offset.y + 68.0 + key_rec_spacing * 2,
                    width = line03_widths[index],
                    height = 38.0,
                ),
                line03_keys[index],
            )
            rec_offset_x += line03_widths[index] + key_rec_spacing

        rec_offset_x = 0
        for index in range(0, 14):
            draw_keyboard_key(
                rl.Rectangle(
                    x = keyboard_offset.x + rec_offset_x,
                    y = keyboard_offset.y + 106.0 + key_rec_spacing * 3,
                    width = line04_widths[index],
                    height = 38.0,
                ),
                line04_keys[index],
            )
            rec_offset_x += line04_widths[index] + key_rec_spacing

        rec_offset_x = 0
        for index in range(0, 14):
            draw_keyboard_key(
                rl.Rectangle(
                    x = keyboard_offset.x + rec_offset_x,
                    y = keyboard_offset.y + 144.0 + key_rec_spacing * 4,
                    width = line05_widths[index],
                    height = 38.0,
                ),
                line05_keys[index],
            )
            rec_offset_x += line05_widths[index] + key_rec_spacing

        rec_offset_x = 0
        for index in range(0, 11):
            draw_keyboard_key(
                rl.Rectangle(
                    x = keyboard_offset.x + rec_offset_x,
                    y = keyboard_offset.y + 182.0 + key_rec_spacing * 5,
                    width = line06_widths[index],
                    height = 38.0,
                ),
                line06_keys[index],
            )
            rec_offset_x += line06_widths[index] + key_rec_spacing

    return 0
