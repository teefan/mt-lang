module examples.idiomatic.raygui.dynamic_string_lists_showcase

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
    var list_scroll: i32 = 0
    var list_active: i32 = 1
    var list_focus: i32 = -1

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("raygui dynamic string lists on the curated surface", 24, 20, 22, rl.DARKGRAY)
        rl.draw_text("tab_bar and list_view_ex accept span[str]; the foreign boundary owns the cstring temps", 24, 52, 18, rl.GRAY)

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
        gui.label(rl.Rectangle(x = 40.0, y = 318.0, width = 220.0, height = 24.0), "Labels rebuild from ordinary array[str] values")
        gui.label(rl.Rectangle(x = 40.0, y = 350.0, width = 220.0, height = 24.0), "No explicit cstr list buffer shows up at the call site")

        gui.group_box(rl.Rectangle(x = 320.0, y = 96.0, width = 600.0, height = 420.0), "Dynamic preview")

        var current_tabs = array[str, 3](
            if compact_labels: "Live" else: "Live Queue",
            if compact_labels: "Inspect" else: "Inspect State",
            if compact_labels: "Focus" else: "Focus Notes",
        )
        gui.tab_bar(
            rl.Rectangle(x = 344.0, y = 132.0, width = 540.0, height = 32.0),
            current_tabs,
            inout tab_active,
        )

        var current_tab_label = "Tab: focus"
        if tab_active == 0:
            current_tab_label = "Tab: live"
        elif tab_active == 1:
            current_tab_label = "Tab: inspect"

        var current_items = array[str, 5](
            if slider_value < 50.0: "Intensity: calm" else: "Intensity: bright",
            if compact_labels: "Wording: compact" else: "Wording: verbose",
            current_tab_label,
            if list_active >= 2: "Selection: later" else: "Selection: early",
            if emphasize_focus and list_focus >= 0: "Focus: highlighted" else: "Focus: open",
        )
        gui.list_view_ex(
            rl.Rectangle(x = 344.0, y = 196.0, width = 260.0, height = 188.0),
            current_items,
            inout list_scroll,
            inout list_active,
            inout list_focus,
        )

        if tab_active == 0:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Live Queue rebuilds labels from toggle and slider state")
        elif tab_active == 1:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Inspect State stays on ordinary span[str] values")
        else:
            gui.label(rl.Rectangle(x = 632.0, y = 202.0, width = 240.0, height = 24.0), "Focus Notes prove the imported boundary handles the temp list")

        gui.label(rl.Rectangle(x = 632.0, y = 238.0, width = 240.0, height = 24.0), "Each frame builds plain string arrays and passes them straight through")
        gui.label(rl.Rectangle(x = 632.0, y = 274.0, width = 240.0, height = 24.0), "No scratch arena, no explicit cstring list storage, no raw imports")
        gui.label(rl.Rectangle(x = 632.0, y = 310.0, width = 240.0, height = 24.0), "The imported raygui surface owns the ABI conversion work")

        rl.draw_rectangle(632, 356, i32<-slider_value * 2, 24, rl.SKYBLUE)
        rl.draw_rectangle_lines(632, 356, 200, 24, rl.DARKGRAY)
        rl.draw_text("live intensity preview", 632, 390, 18, rl.DARKGRAY)

    return 0