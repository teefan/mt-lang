module examples.idiomatic.raygui.cstr_list_buffers_showcase

import std.raylib as rl
import std.raygui as gui

const screen_width: i32 = 940
const screen_height: i32 = 560

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Raygui Dynamic String Lists")
    defer rl.close_window()

    gui.set_state(gui.State.STATE_NORMAL)
    rl.set_target_fps(60)

    var compact_labels = false
    var emphasize_focus = true
    var slider_value: f32 = 48.0
    var tab_active: i32 = 0
    var tab_labels: cstr_list_buffer[3, 96]
    var list_scroll: i32 = 0
    var list_active: i32 = 1
    var list_focus: i32 = -1
    var list_labels: cstr_list_buffer[5, 224]

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("raygui dynamic string lists with explicit caller-owned storage", 24, 20, 22, rl.DARKGRAY)
        rl.draw_text("No hidden scratch marshalling: assign(span[str]) copies into local cstr_list_buffer storage", 24, 52, 18, rl.GRAY)

        gui.group_box(rl.Rectangle(x = 20.0, y = 96.0, width = 280.0, height = 420.0), "Inputs")
        gui.label(rl.Rectangle(x = 40.0, y = 128.0, width = 220.0, height = 24.0), "Rebuild labels from live state each frame")
        if gui.button(rl.Rectangle(x = 40.0, y = 164.0, width = 180.0, height = 34.0), "Flip wording") != 0:
            compact_labels = not compact_labels

        gui.check_box(rl.Rectangle(x = 40.0, y = 220.0, width = 20.0, height = 20.0), "Keep focus callout", inout emphasize_focus)
        gui.slider(
            rl.Rectangle(x = 40.0, y = 268.0, width = 200.0, height = 24.0),
            "Quiet",
            "Loud",
            inout slider_value,
            0.0,
            100.0,
        )
        gui.label(rl.Rectangle(x = 40.0, y = 318.0, width = 220.0, height = 24.0), "Pick the Empty tab to exercise clear()")
        gui.label(rl.Rectangle(x = 40.0, y = 350.0, width = 220.0, height = 24.0), "The preview list stays on span[cstr]")

        gui.group_box(rl.Rectangle(x = 320.0, y = 96.0, width = 600.0, height = 420.0), "Dynamic preview")

        var current_tabs = array[str, 3](
            if compact_labels then "Live" else "Live Queue",
            if compact_labels then "Inspect" else "Inspect State",
            if compact_labels then "Empty" else "Empty Queue",
        )
        tab_labels.assign(current_tabs)
        let visible_tabs = tab_labels.as_cstrs()
        gui.tab_bar(
            rl.Rectangle(x = 344.0, y = 132.0, width = 540.0, height = 32.0),
            visible_tabs,
            inout tab_active,
        )

        if tab_active == 2:
            list_labels.clear()
        else:
            var current_items = array[str, 5](
                if slider_value < 50.0 then "Intensity: calm" else "Intensity: bright",
                if compact_labels then "Wording: compact" else "Wording: verbose",
                if tab_active == 0 then "Tab: live" else "Tab: inspect",
                if list_active >= 2 then "Selection: later" else "Selection: early",
                if emphasize_focus and list_focus >= 0 then "Focus: highlighted" else "Focus: open",
            )
            list_labels.assign(current_items)

        let visible_items = list_labels.as_cstrs()
        gui.list_view_ex(
            rl.Rectangle(x = 344.0, y = 196.0, width = 260.0, height = 188.0),
            visible_items,
            inout list_scroll,
            inout list_active,
            inout list_focus,
        )

        if tab_active == 0:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Live Queue rebuilds labels from toggle and slider state")
        elif tab_active == 1:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Inspect State keeps the same curated span[cstr] surface")
        else:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Empty Queue proves clear() returns an empty borrowed list")

        if visible_items.len == 0:
            gui.label(rl.Rectangle(x = 632.0, y = 238.0, width = 240.0, height = 24.0), "clear() yields len = 0 with no scratch storage")
        else:
            gui.label(rl.Rectangle(x = 632.0, y = 238.0, width = 240.0, height = 24.0), "assign(span[str]) repacks entries into explicit local cstr storage")

        if list_labels.capacity() == cast[usize](5):
            gui.label(rl.Rectangle(x = 632.0, y = 274.0, width = 240.0, height = 24.0), "list_labels reserves 5 entries and 224 backing bytes")

        if tab_labels.byte_capacity() == cast[usize](96):
            gui.label(rl.Rectangle(x = 632.0, y = 310.0, width = 240.0, height = 24.0), "tab_labels keeps its own 96-byte backing store")

        rl.draw_rectangle(632, 356, cast[i32](slider_value) * 2, 24, rl.SKYBLUE)
        rl.draw_rectangle_lines(632, 356, 200, 24, rl.DARKGRAY)
        rl.draw_text("live intensity preview", 632, 390, 18, rl.DARKGRAY)

    return 0
