module examples.idiomatic.raygui.controls_showcase

import std.raylib as rl
import std.raygui as gui

const screen_width: i32 = 960
const screen_height: i32 = 560


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Raygui Controls Showcase")
    defer rl.close_window()

    gui.set_state(gui.State.STATE_NORMAL)
    rl.set_target_fps(60)

    var toggle_enabled = true
    var checked = false
    var tab_active: i32 = 0
    var tab_labels = array[str, 3]("Layout", "Palette", "About")
    var combo_active: i32 = 1
    var slider_value: f32 = 42.0
    var progress_value: f32 = 42.0
    var list_scroll: i32 = 0
    var list_active: i32 = 2
    var list_focus: i32 = -1
    var accent = rl.Color(r = 110, g = 170, b = 255, a = 255)
    var mouse_cell = rl.Vector2(x = -1.0, y = -1.0)

    while not rl.window_should_close():
        progress_value = slider_value

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("raygui imported surface pressure test", 24, 18, 20, rl.DARKGRAY)
        rl.draw_text("shared structs and dynamic string lists stay on the curated span[str] surface", 24, 44, 18, rl.GRAY)

        let left_panel = rl.Rectangle(x = 20.0, y = 84.0, width = 300.0, height = 440.0)
        let right_panel = rl.Rectangle(x = 340.0, y = 84.0, width = 600.0, height = 440.0)
        let tab_caption_bounds = rl.Rectangle(x = 360.0, y = 166.0, width = 520.0, height = 24.0)

        gui.group_box(left_panel, "Controls")
        gui.label(rl.Rectangle(x = 40.0, y = 118.0, width = 240.0, height = 24.0), "Compact second-pass raygui surface")
        if gui.button(rl.Rectangle(x = 40.0, y = 152.0, width = 120.0, height = 32.0), "Flip toggles") != 0:
            toggle_enabled = not toggle_enabled
            checked = not checked

        gui.toggle(rl.Rectangle(x = 40.0, y = 200.0, width = 120.0, height = 32.0), "Enabled", inout toggle_enabled)
        gui.check_box(rl.Rectangle(x = 40.0, y = 248.0, width = 20.0, height = 20.0), "Checked", inout checked)
        gui.combo_box(rl.Rectangle(x = 40.0, y = 292.0, width = 180.0, height = 32.0), "Ocean;Forest;Sunset;Mono", inout combo_active)
        gui.slider(
            rl.Rectangle(x = 40.0, y = 344.0, width = 200.0, height = 24.0),
            "Low",
            "High",
            inout slider_value,
            0.0,
            100.0,
        )
        gui.progress_bar(
            rl.Rectangle(x = 40.0, y = 388.0, width = 200.0, height = 20.0),
            "",
            "",
            inout progress_value,
            0.0,
            100.0,
        )
        var list_entries = array[str, 5](
            if toggle_enabled: "Toggle: enabled" else: "Toggle: disabled",
            if checked: "Check: on" else: "Check: off",
            if combo_active < 2: "Theme: cool" else: "Theme: bold",
            if tab_active == 0: "Tab: layout" else: "Tab: focus",
            if list_focus >= 0: "Focus: active" else: "Focus: none",
        )
        gui.list_view_ex(
            rl.Rectangle(x = 40.0, y = 424.0, width = 240.0, height = 84.0),
            list_entries,
            inout list_scroll,
            inout list_active,
            inout list_focus,
        )

        gui.group_box(right_panel, "Shared raylib values")
        gui.tab_bar(
            rl.Rectangle(x = 360.0, y = 118.0, width = 520.0, height = 32.0),
            tab_labels,
            inout tab_active,
        )
        if tab_active == 0:
            gui.label(tab_caption_bounds, "Compact second-pass raygui surface")
        elif tab_active == 1:
            gui.label(tab_caption_bounds, "Literal string arrays lower directly through the curated surface")
        else:
            gui.label(tab_caption_bounds, "No raw pointers or unsafe blocks in this example")
        gui.color_picker(
            rl.Rectangle(x = 360.0, y = 214.0, width = 260.0, height = 220.0),
            "Accent",
            inout accent,
        )
        gui.grid(
            rl.Rectangle(x = 660.0, y = 214.0, width = 240.0, height = 220.0),
            "Grid",
            24.0,
            4,
            out mouse_cell,
        )

        rl.draw_rectangle(360, 364, 160, 80, accent)
        rl.draw_rectangle_lines(360, 364, 160, 80, rl.DARKGRAY)
        rl.draw_text("accent preview", 360, 454, 20, rl.DARKGRAY)

        if mouse_cell.x >= 0.0:
            if mouse_cell.y >= 0.0:
                let marker_x = 660 + i32<-(mouse_cell.x * 24.0) + 12
                let marker_y = 214 + i32<-(mouse_cell.y * 24.0) + 12
                rl.draw_circle(marker_x, marker_y, 5.0, accent)

    return 0
