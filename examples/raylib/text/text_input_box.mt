module examples.raylib.text.text_input_box

import std.c.raylib as rl

const max_input_chars: int = 9
const max_input_bytes: int = 10
const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [text] example - input box"
const prompt_text: cstr = c"PLACE MOUSE OVER INPUT BOX!"
const counter_format: cstr = c"INPUT CHARS: %i/%i"
const backspace_text: cstr = c"Press BACKSPACE to delete chars..."
const underscore_text: cstr = c"_"


def cstr_from_bytes(bytes: ptr[ubyte]) -> cstr:
    unsafe:
        return cstr<-bytes


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var name = zero[array[ubyte, max_input_bytes]]
    var letter_count = 0

    let text_box = rl.Rectangle(
        x = float<-screen_width / 2.0 - 100.0,
        y = 180.0,
        width = 225.0,
        height = 50.0,
    )

    var mouse_on_text = false
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        mouse_on_text = rl.CheckCollisionPointRec(rl.GetMousePosition(), text_box)

        if mouse_on_text:
            rl.SetMouseCursor(rl.MouseCursor.MOUSE_CURSOR_IBEAM)

            var key = rl.GetCharPressed()
            while key > 0:
                if key >= 32 and key <= 125 and letter_count < max_input_chars:
                    name[letter_count] = ubyte<-key
                    name[letter_count + 1] = ubyte<-0
                    letter_count += 1

                key = rl.GetCharPressed()

            if rl.IsKeyPressed(rl.KeyboardKey.KEY_BACKSPACE):
                letter_count -= 1
                if letter_count < 0:
                    letter_count = 0
                name[letter_count] = ubyte<-0
        else:
            rl.SetMouseCursor(rl.MouseCursor.MOUSE_CURSOR_DEFAULT)

        if mouse_on_text:
            frames_counter += 1
        else:
            frames_counter = 0

        let name_text = cstr_from_bytes(ptr_of(name[0]))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(prompt_text, 240, 140, 20, rl.GRAY)

        rl.DrawRectangleRec(text_box, rl.LIGHTGRAY)
        if mouse_on_text:
            rl.DrawRectangleLines(int<-text_box.x, int<-text_box.y, int<-text_box.width, int<-text_box.height, rl.RED)
        else:
            rl.DrawRectangleLines(int<-text_box.x, int<-text_box.y, int<-text_box.width, int<-text_box.height, rl.DARKGRAY)

        rl.DrawText(name_text, int<-text_box.x + 5, int<-text_box.y + 8, 40, rl.MAROON)
        rl.DrawText(rl.TextFormat(counter_format, letter_count, max_input_chars), 315, 250, 20, rl.DARKGRAY)

        if mouse_on_text:
            if letter_count < max_input_chars:
                if ((frames_counter / 20) % 2) == 0:
                    rl.DrawText(underscore_text, int<-text_box.x + 8 + rl.MeasureText(name_text, 40), int<-text_box.y + 12, 40, rl.MAROON)
            else:
                rl.DrawText(backspace_text, 230, 300, 20, rl.GRAY)

    return 0
