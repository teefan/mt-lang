import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_TEXT_SAMPLES: int = 5


function update_clipboard_buffer(buffer: ref[str_buffer[256]]) -> void:
    let clipboard_text = text.cstr_as_str(rl.get_clipboard_text())
    unsafe: read(buffer).assign(clipboard_text)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - clipboard text")
    defer rl.close_window()

    let sample_texts = array[str, 5](
        "Hello from raylib!",
        "The quick brown fox jumps over the lazy dog",
        "Clipboard operations are useful!",
        "raylib is a simple and easy-to-use library",
        "Copy and paste me!",
    )

    var input_buffer: str_buffer[256]
    input_buffer.assign("Hello from raylib!")
    var clipboard_buffer: str_buffer[256]
    clipboard_buffer.assign("")

    var text_box_edit_mode = false

    gui.set_style(gui.Control.DEFAULT, int<-gui.DefaultProperty.TEXT_SIZE, 20)
    gui.set_icon_scale(2)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) or rl.is_key_down(rl.KeyboardKey.KEY_RIGHT_CONTROL):
            if rl.is_key_pressed(rl.KeyboardKey.KEY_X):
                rl.set_clipboard_text(input_buffer.as_str())
                input_buffer.clear()
            if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
                rl.set_clipboard_text(input_buffer.as_str())
            if rl.is_key_pressed(rl.KeyboardKey.KEY_V):
                input_buffer.assign(text.cstr_as_str(rl.get_clipboard_text()))
            update_clipboard_buffer(ref_of(clipboard_buffer))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        gui.label(gui.Rectangle(x = 50.0, y = 20.0, width = 700.0, height = 36.0), "Use the BUTTONS or KEY SHORTCUTS:")
        rl.draw_text("[CTRL+X] - CUT | [CTRL+C] COPY | [CTRL+V] | PASTE", 50, 60, 20, rl.MAROON)

        if gui.text_box(gui.Rectangle(x = 50.0, y = 120.0, width = 652.0, height = 40.0), input_buffer, text_box_edit_mode) != 0:
            text_box_edit_mode = not text_box_edit_mode

        let btn_random_pressed = gui.button(gui.Rectangle(x = 710.0, y = 120.0, width = 40.0, height = 40.0), "#77#") != 0
        let btn_cut_pressed = gui.button(gui.Rectangle(x = 50.0, y = 180.0, width = 158.0, height = 40.0), "#17#CUT") != 0
        let btn_copy_pressed = gui.button(gui.Rectangle(x = 215.0, y = 180.0, width = 158.0, height = 40.0), "#16#COPY") != 0
        let btn_paste_pressed = gui.button(gui.Rectangle(x = 380.0, y = 180.0, width = 158.0, height = 40.0), "#18#PASTE") != 0
        let btn_clear_pressed = gui.button(gui.Rectangle(x = 545.0, y = 180.0, width = 158.0, height = 40.0), "#143#CLEAR") != 0

        if btn_cut_pressed:
            rl.set_clipboard_text(input_buffer.as_str())
            input_buffer.clear()
        if btn_copy_pressed:
            rl.set_clipboard_text(input_buffer.as_str())
        if btn_paste_pressed:
            input_buffer.assign(text.cstr_as_str(rl.get_clipboard_text()))
        if btn_clear_pressed:
            input_buffer.clear()
        if btn_random_pressed:
            input_buffer.assign(sample_texts[rl.get_random_value(0, MAX_TEXT_SAMPLES - 1)])

        update_clipboard_buffer(ref_of(clipboard_buffer))

        gui.set_state(gui.State.STATE_DISABLED)
        gui.label(gui.Rectangle(x = 50.0, y = 260.0, width = 700.0, height = 40.0), "Clipboard current text data:")
        gui.set_style(gui.Control.TEXTBOX, int<-gui.TextBoxProperty.TEXT_READONLY, 1)
        unsafe: gui.text_box(gui.Rectangle(x = 50.0, y = 300.0, width = 700.0, height = 40.0), clipboard_buffer, false)
        gui.set_style(gui.Control.TEXTBOX, int<-gui.TextBoxProperty.TEXT_READONLY, 0)
        gui.label(gui.Rectangle(x = 50.0, y = 360.0, width = 700.0, height = 40.0), "Try copying text from other applications and pasting here!")
        gui.set_state(gui.State.STATE_NORMAL)

        rl.end_drawing()

    return 0
