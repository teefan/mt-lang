import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const KEY_REC_SPACING: int = 4


function draw_keyboard_key(bounds: rl.Rectangle, key: int, label: str) -> void:
    if key == int<-rl.KeyboardKey.KEY_NULL:
        rl.draw_rectangle_lines_ex(bounds, 2.0, rl.LIGHTGRAY)
    else if rl.is_key_down(rl.KeyboardKey<-key):
        rl.draw_rectangle_lines_ex(bounds, 2.0, rl.MAROON)
        rl.draw_text(label, int<-(bounds.x + 4.0), int<-(bounds.y + 4.0), 10, rl.MAROON)
    else:
        rl.draw_rectangle_lines_ex(bounds, 2.0, rl.DARKGRAY)
        rl.draw_text(label, int<-(bounds.x + 4.0), int<-(bounds.y + 4.0), 10, rl.DARKGRAY)

    if rl.check_collision_point_rec(rl.get_mouse_position(), bounds):
        rl.draw_rectangle_rec(bounds, rl.fade(rl.RED, 0.2))
        rl.draw_rectangle_lines_ex(bounds, 3.0, rl.RED)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - keyboard testbed")
    defer rl.close_window()
    rl.set_exit_key(rl.KeyboardKey.KEY_NULL)

    let line01_key_widths = array[int, 15](45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 62, 45)
    let line01_keys = array[int, 15](
        int<-rl.KeyboardKey.KEY_ESCAPE, int<-rl.KeyboardKey.KEY_F1, int<-rl.KeyboardKey.KEY_F2, int<-rl.KeyboardKey.KEY_F3, int<-rl.KeyboardKey.KEY_F4,
        int<-rl.KeyboardKey.KEY_F5, int<-rl.KeyboardKey.KEY_F6, int<-rl.KeyboardKey.KEY_F7, int<-rl.KeyboardKey.KEY_F8, int<-rl.KeyboardKey.KEY_F9,
        int<-rl.KeyboardKey.KEY_F10, int<-rl.KeyboardKey.KEY_F11, int<-rl.KeyboardKey.KEY_F12, int<-rl.KeyboardKey.KEY_PRINT_SCREEN, int<-rl.KeyboardKey.KEY_PAUSE,
    )
    let line01_labels = array[str, 15]("ESC", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "PRINTSCR", "PAUSE")

    let line02_key_widths = array[int, 15](25, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 82, 45)
    let line02_keys = array[int, 15](
        int<-rl.KeyboardKey.KEY_GRAVE, int<-rl.KeyboardKey.KEY_ONE, int<-rl.KeyboardKey.KEY_TWO, int<-rl.KeyboardKey.KEY_THREE, int<-rl.KeyboardKey.KEY_FOUR,
        int<-rl.KeyboardKey.KEY_FIVE, int<-rl.KeyboardKey.KEY_SIX, int<-rl.KeyboardKey.KEY_SEVEN, int<-rl.KeyboardKey.KEY_EIGHT, int<-rl.KeyboardKey.KEY_NINE,
        int<-rl.KeyboardKey.KEY_ZERO, int<-rl.KeyboardKey.KEY_MINUS, int<-rl.KeyboardKey.KEY_EQUAL, int<-rl.KeyboardKey.KEY_BACKSPACE, int<-rl.KeyboardKey.KEY_DELETE,
    )
    let line02_labels = array[str, 15]("`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "BACK", "DEL")

    let line03_key_widths = array[int, 15](50, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 57, 45)
    let line03_keys = array[int, 15](
        int<-rl.KeyboardKey.KEY_TAB, int<-rl.KeyboardKey.KEY_Q, int<-rl.KeyboardKey.KEY_W, int<-rl.KeyboardKey.KEY_E, int<-rl.KeyboardKey.KEY_R,
        int<-rl.KeyboardKey.KEY_T, int<-rl.KeyboardKey.KEY_Y, int<-rl.KeyboardKey.KEY_U, int<-rl.KeyboardKey.KEY_I, int<-rl.KeyboardKey.KEY_O,
        int<-rl.KeyboardKey.KEY_P, int<-rl.KeyboardKey.KEY_LEFT_BRACKET, int<-rl.KeyboardKey.KEY_RIGHT_BRACKET, int<-rl.KeyboardKey.KEY_BACKSLASH, int<-rl.KeyboardKey.KEY_INSERT,
    )
    let line03_labels = array[str, 15]("TAB", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\", "INS")

    let line04_key_widths = array[int, 14](68, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 88, 45)
    let line04_keys = array[int, 14](
        int<-rl.KeyboardKey.KEY_CAPS_LOCK, int<-rl.KeyboardKey.KEY_A, int<-rl.KeyboardKey.KEY_S, int<-rl.KeyboardKey.KEY_D, int<-rl.KeyboardKey.KEY_F,
        int<-rl.KeyboardKey.KEY_G, int<-rl.KeyboardKey.KEY_H, int<-rl.KeyboardKey.KEY_J, int<-rl.KeyboardKey.KEY_K, int<-rl.KeyboardKey.KEY_L,
        int<-rl.KeyboardKey.KEY_SEMICOLON, int<-rl.KeyboardKey.KEY_APOSTROPHE, int<-rl.KeyboardKey.KEY_ENTER, int<-rl.KeyboardKey.KEY_PAGE_UP,
    )
    let line04_labels = array[str, 14]("CAPS", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "ENTER", "PGUP")

    let line05_key_widths = array[int, 14](80, 45, 45, 45, 45, 45, 45, 45, 45, 45, 45, 76, 45, 45)
    let line05_keys = array[int, 14](
        int<-rl.KeyboardKey.KEY_LEFT_SHIFT, int<-rl.KeyboardKey.KEY_Z, int<-rl.KeyboardKey.KEY_X, int<-rl.KeyboardKey.KEY_C, int<-rl.KeyboardKey.KEY_V,
        int<-rl.KeyboardKey.KEY_B, int<-rl.KeyboardKey.KEY_N, int<-rl.KeyboardKey.KEY_M, int<-rl.KeyboardKey.KEY_COMMA, int<-rl.KeyboardKey.KEY_PERIOD,
        int<-rl.KeyboardKey.KEY_SLASH, int<-rl.KeyboardKey.KEY_RIGHT_SHIFT, int<-rl.KeyboardKey.KEY_UP, int<-rl.KeyboardKey.KEY_PAGE_DOWN,
    )
    let line05_labels = array[str, 14]("LSHIFT", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "RSHIFT", "UP", "PGDOWN")

    let line06_key_widths = array[int, 11](80, 45, 45, 208, 45, 45, 45, 60, 45, 45, 45)
    let line06_keys = array[int, 11](
        int<-rl.KeyboardKey.KEY_LEFT_CONTROL, int<-rl.KeyboardKey.KEY_LEFT_SUPER, int<-rl.KeyboardKey.KEY_LEFT_ALT, int<-rl.KeyboardKey.KEY_SPACE,
        int<-rl.KeyboardKey.KEY_RIGHT_ALT, 162, int<-rl.KeyboardKey.KEY_NULL, int<-rl.KeyboardKey.KEY_RIGHT_CONTROL,
        int<-rl.KeyboardKey.KEY_LEFT, int<-rl.KeyboardKey.KEY_DOWN, int<-rl.KeyboardKey.KEY_RIGHT,
    )
    let line06_labels = array[str, 11]("LCTRL", "WIN", "LALT", "SPACE", "ALTGR", "\\", "FN", "RCTRL", "LEFT", "DOWN", "RIGHT")

    let keyboard_offset = rl.Vector2(x = 26.0, y = 80.0)
    rl.set_target_fps(60)

    while not rl.window_should_close():
        unsafe: rl.get_key_pressed()
        unsafe: rl.get_char_pressed()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("KEYBOARD LAYOUT: ENG-US", 26, 38, 20, rl.LIGHTGRAY)

        var rec_offset_x = 0
        var index = 0
        while index < 15:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y, width = float<-line01_key_widths[index], height = 30.0), line01_keys[index], line01_labels[index])
            rec_offset_x += line01_key_widths[index] + KEY_REC_SPACING
            index += 1

        rec_offset_x = 0
        index = 0
        while index < 15:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y + 30.0 + float<-KEY_REC_SPACING, width = float<-line02_key_widths[index], height = 38.0), line02_keys[index], line02_labels[index])
            rec_offset_x += line02_key_widths[index] + KEY_REC_SPACING
            index += 1

        rec_offset_x = 0
        index = 0
        while index < 15:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y + 30.0 + 38.0 + float<-(KEY_REC_SPACING * 2), width = float<-line03_key_widths[index], height = 38.0), line03_keys[index], line03_labels[index])
            rec_offset_x += line03_key_widths[index] + KEY_REC_SPACING
            index += 1

        rec_offset_x = 0
        index = 0
        while index < 14:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y + 30.0 + 38.0 * 2.0 + float<-(KEY_REC_SPACING * 3), width = float<-line04_key_widths[index], height = 38.0), line04_keys[index], line04_labels[index])
            rec_offset_x += line04_key_widths[index] + KEY_REC_SPACING
            index += 1

        rec_offset_x = 0
        index = 0
        while index < 14:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y + 30.0 + 38.0 * 3.0 + float<-(KEY_REC_SPACING * 4), width = float<-line05_key_widths[index], height = 38.0), line05_keys[index], line05_labels[index])
            rec_offset_x += line05_key_widths[index] + KEY_REC_SPACING
            index += 1

        rec_offset_x = 0
        index = 0
        while index < 11:
            draw_keyboard_key(rl.Rectangle(x = keyboard_offset.x + float<-rec_offset_x, y = keyboard_offset.y + 30.0 + 38.0 * 4.0 + float<-(KEY_REC_SPACING * 5), width = float<-line06_key_widths[index], height = 38.0), line06_keys[index], line06_labels[index])
            rec_offset_x += line06_key_widths[index] + KEY_REC_SPACING
            index += 1

        rl.end_drawing()

    return 0
