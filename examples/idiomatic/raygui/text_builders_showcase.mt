module examples.idiomatic.raygui.text_builders_showcase

import std.raylib as rl
import std.raygui as gui

const screen_width: i32 = 920
const screen_height: i32 = 540

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Raygui Text Builders")
    defer rl.close_window()

    gui.set_state(gui.State.STATE_NORMAL)
    rl.set_target_fps(60)

    var editor_text: str_builder[64]
    var editor_active = false
    var value_text: str_builder[32]
    var value_active = false
    var value: f32 = 48.0
    var show_dialog = false
    var dialog_text: str_builder[64]
    var secret_view = false
    var last_dialog_result: i32 = -1

    editor_text.assign("Milk Tea")
    value_text.assign("48.0")

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("raygui mutable text now uses str_builder on the caller side", 28, 20, 22, rl.DARKGRAY)
        rl.draw_text("Editable raygui text now uses direct str_builder[N] public signatures without wrapper APIs", 28, 52, 18, rl.GRAY)

        gui.group_box(rl.Rectangle(x = 20.0, y = 92.0, width = 410.0, height = 410.0), "Editable text")
        gui.label(rl.Rectangle(x = 40.0, y = 126.0, width = 340.0, height = 24.0), "GuiTextBox consumes a writable span, but callers use str_builder")
        if gui.text_box(rl.Rectangle(x = 40.0, y = 160.0, width = 320.0, height = 36.0), editor_text, editor_active) != 0:
            editor_active = not editor_active

        gui.label(rl.Rectangle(x = 40.0, y = 218.0, width = 340.0, height = 24.0), "GuiValueBoxFloat reuses the same tracked-length builder")
        if gui.value_box_float(
            rl.Rectangle(x = 40.0, y = 252.0, width = 220.0, height = 36.0),
            "Opacity",
            value_text,
            inout value,
            value_active,
        ) != 0:
            value_active = not value_active

        gui.label(rl.Rectangle(x = 40.0, y = 308.0, width = 340.0, height = 24.0), "GuiTextInputBox writes back into the same builder")
        if gui.button(rl.Rectangle(x = 40.0, y = 342.0, width = 220.0, height = 36.0), "Open text input dialog") != 0:
            dialog_text.clear()
            dialog_text.assign(editor_text.as_str())
            show_dialog = true

        let swatch_width = 80 + i32<-value * 2
        rl.draw_rectangle(40, 412, swatch_width, 28, rl.SKYBLUE)
        rl.draw_rectangle_lines(40, 412, 280, 28, rl.DARKGRAY)
        rl.draw_text("value preview", 40, 448, 18, rl.DARKGRAY)

        gui.group_box(rl.Rectangle(x = 460.0, y = 92.0, width = 430.0, height = 410.0), "Builder state")
        gui.label(rl.Rectangle(x = 480.0, y = 126.0, width = 360.0, height = 24.0), "Close the dialog with OK or Cancel to update the result")
        if show_dialog:
            gui.label(rl.Rectangle(x = 480.0, y = 162.0, width = 360.0, height = 24.0), "Dialog open")
        else:
            gui.label(rl.Rectangle(x = 480.0, y = 162.0, width = 360.0, height = 24.0), "Dialog closed")

        if secret_view:
            gui.label(rl.Rectangle(x = 480.0, y = 198.0, width = 360.0, height = 24.0), "Secret view enabled")
        else:
            gui.label(rl.Rectangle(x = 480.0, y = 198.0, width = 360.0, height = 24.0), "Secret view disabled")

        gui.label(rl.Rectangle(x = 480.0, y = 234.0, width = 360.0, height = 24.0), "Current dialog text")
        gui.label(rl.Rectangle(x = 480.0, y = 262.0, width = 360.0, height = 24.0), dialog_text.as_cstr())

        if dialog_text.capacity() == 64:
            gui.label(rl.Rectangle(x = 480.0, y = 298.0, width = 360.0, height = 24.0), "Dialog builder capacity: 64 bytes plus trailing NUL")

        if last_dialog_result < 0:
            gui.label(rl.Rectangle(x = 480.0, y = 334.0, width = 360.0, height = 24.0), "Last dialog result: pending")
        elif last_dialog_result == 0:
            gui.label(rl.Rectangle(x = 480.0, y = 334.0, width = 360.0, height = 24.0), "Last dialog result: OK")
        else:
            gui.label(rl.Rectangle(x = 480.0, y = 334.0, width = 360.0, height = 24.0), "Last dialog result: Cancel")

        if show_dialog:
            let dialog_result = gui.text_input_box(
                rl.Rectangle(x = 220.0, y = 120.0, width = 480.0, height = 220.0),
                "Rename preset",
                "Enter a label for the preview swatch",
                "OK;Cancel",
                dialog_text,
                inout secret_view,
            )
            if dialog_result >= 0:
                show_dialog = false
                last_dialog_result = dialog_result
                if dialog_result == 0:
                    editor_text.assign(dialog_text.as_str())

    return 0