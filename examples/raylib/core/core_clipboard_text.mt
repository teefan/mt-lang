module examples.raylib.core.core_clipboard_text

import std.c.raylib as rl
import std.c.raygui as gui

const screen_width: i32 = 800
const screen_height: i32 = 450
const input_buffer_size: i32 = 256
const window_title: cstr = c"raylib [core] example - clipboard text"
const shortcut_text: cstr = c"[CTRL+X] - CUT | [CTRL+C] COPY | [CTRL+V] | PASTE"
const instruction_text: cstr = c"Use the BUTTONS or KEY SHORTCUTS:"
const clipboard_label_text: cstr = c"Clipboard current text data:"
const clipboard_help_text: cstr = c"Try copying text from other applications and pasting here!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let sample_texts = array[cstr, 5](
        c"Hello from raylib!",
        c"The quick brown fox jumps over the lazy dog",
        c"Clipboard operations are useful!",
        c"raylib is a simple and easy-to-use library",
        c"Copy and paste me!",
    )

    var clipboard_text = c""
    var input_buffer = zero[array[char, 256]]()
    var clipboard_buffer = zero[array[char, 256]]()
    let input_buffer_ptr = ptr_of(input_buffer[0])
    let clipboard_buffer_ptr = ptr_of(clipboard_buffer[0])

    rl.TextCopy(input_buffer_ptr, c"Hello from raylib!")
    rl.TextCopy(clipboard_buffer_ptr, clipboard_text)

    var text_box_edit_mode = false
    var btn_cut_pressed = false
    var btn_copy_pressed = false
    var btn_paste_pressed = false
    var btn_clear_pressed = false
    var btn_random_pressed = false

    gui.GuiSetStyle(gui.GuiControl.DEFAULT, gui.GuiDefaultProperty.TEXT_SIZE, 20)
    gui.GuiSetIconScale(2)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if btn_cut_pressed:
            unsafe:
                rl.SetClipboardText(cstr<-input_buffer_ptr)
            clipboard_text = rl.GetClipboardText()
            rl.TextCopy(clipboard_buffer_ptr, clipboard_text)
            rl.TextCopy(input_buffer_ptr, c"")

        if btn_copy_pressed:
            unsafe:
                rl.SetClipboardText(cstr<-input_buffer_ptr)
            clipboard_text = rl.GetClipboardText()
            rl.TextCopy(clipboard_buffer_ptr, clipboard_text)

        if btn_paste_pressed:
            clipboard_text = rl.GetClipboardText()
            rl.TextCopy(input_buffer_ptr, clipboard_text)
            rl.TextCopy(clipboard_buffer_ptr, clipboard_text)

        if btn_clear_pressed:
            rl.TextCopy(input_buffer_ptr, c"")

        if btn_random_pressed:
            let sample_index = rl.GetRandomValue(0, 4)
            rl.TextCopy(input_buffer_ptr, sample_texts[sample_index])

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT_CONTROL):
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_X):
                unsafe:
                    rl.SetClipboardText(cstr<-input_buffer_ptr)
                clipboard_text = rl.GetClipboardText()
                rl.TextCopy(clipboard_buffer_ptr, clipboard_text)
                rl.TextCopy(input_buffer_ptr, c"")

            if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
                unsafe:
                    rl.SetClipboardText(cstr<-input_buffer_ptr)
                clipboard_text = rl.GetClipboardText()
                rl.TextCopy(clipboard_buffer_ptr, clipboard_text)

            if rl.IsKeyPressed(rl.KeyboardKey.KEY_V):
                clipboard_text = rl.GetClipboardText()
                rl.TextCopy(input_buffer_ptr, clipboard_text)
                rl.TextCopy(clipboard_buffer_ptr, clipboard_text)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        gui.GuiLabel(gui.Rectangle(x = 50.0, y = 20.0, width = 700.0, height = 36.0), instruction_text)
        rl.DrawText(shortcut_text, 50, 60, 20, rl.MAROON)

        if gui.GuiTextBox(
            gui.Rectangle(x = 50.0, y = 120.0, width = 652.0, height = 40.0),
            input_buffer_ptr,
            input_buffer_size,
            text_box_edit_mode,
        ) != 0:
            text_box_edit_mode = not text_box_edit_mode

        btn_random_pressed = gui.GuiButton(gui.Rectangle(x = 710.0, y = 120.0, width = 40.0, height = 40.0), c"#77#") != 0
        btn_cut_pressed = gui.GuiButton(gui.Rectangle(x = 50.0, y = 180.0, width = 158.0, height = 40.0), c"#17#CUT") != 0
        btn_copy_pressed = gui.GuiButton(gui.Rectangle(x = 215.0, y = 180.0, width = 158.0, height = 40.0), c"#16#COPY") != 0
        btn_paste_pressed = gui.GuiButton(gui.Rectangle(x = 380.0, y = 180.0, width = 158.0, height = 40.0), c"#18#PASTE") != 0
        btn_clear_pressed = gui.GuiButton(gui.Rectangle(x = 545.0, y = 180.0, width = 158.0, height = 40.0), c"#143#CLEAR") != 0

        gui.GuiSetState(gui.GuiState.STATE_DISABLED)
        gui.GuiLabel(gui.Rectangle(x = 50.0, y = 260.0, width = 700.0, height = 40.0), clipboard_label_text)
        gui.GuiSetStyle(gui.GuiControl.TEXTBOX, gui.GuiTextBoxProperty.TEXT_READONLY, 1)
        gui.GuiTextBox(
            gui.Rectangle(x = 50.0, y = 300.0, width = 700.0, height = 40.0),
            clipboard_buffer_ptr,
            input_buffer_size,
            false,
        )
        gui.GuiSetStyle(gui.GuiControl.TEXTBOX, gui.GuiTextBoxProperty.TEXT_READONLY, 0)
        gui.GuiLabel(gui.Rectangle(x = 50.0, y = 360.0, width = 700.0, height = 40.0), clipboard_help_text)
        gui.GuiSetState(gui.GuiState.STATE_NORMAL)

    return 0
