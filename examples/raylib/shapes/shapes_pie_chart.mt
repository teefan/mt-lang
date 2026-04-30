module examples.raylib.shapes.shapes_pie_chart

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl
import std.raylib.math as rm

const max_pie_slices: i32 = 10
const screen_width: i32 = 800
const screen_height: i32 = 450
const panel_width: f32 = 270.0
const panel_margin: f32 = 5.0
const radius: f32 = 205.0
const window_title: cstr = c"raylib [shapes] example - pie chart"
const slice_name_format: cstr = c"Slice %02i"
const value_percent_format: cstr = c"%.1f (%.0f%%)"
const value_only_format: cstr = c"%.1f"
const percent_only_format: cstr = c"%.0f%%"
const empty_text: cstr = c""
const slices_text: cstr = c"Slices "
const show_values_text: cstr = c"Show Values"
const show_percentages_text: cstr = c"Show Percentages"
const make_donut_text: cstr = c"Make Donut"
const inner_radius_text: cstr = c"Inner Radius"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var slice_count = 7
    var donut_inner_radius: f32 = 25.0
    var values = zero[array[f32, 10]]()
    values[0] = 300.0
    values[1] = 100.0
    values[2] = 450.0
    values[3] = 350.0
    values[4] = 600.0
    values[5] = 380.0
    values[6] = 750.0

    var labels = zero[array[array[char, 32], 10]]()
    var editing_label = zero[array[bool, 10]]()
    for index in range(0, max_pie_slices):
        rl.TextCopy(raw(addr(labels[index][0])), rl.TextFormat(slice_name_format, index + 1))

    var show_values = true
    var show_percentages = false
    var show_donut = false
    var hovered_slice = -1
    var scroll_panel_bounds = gui.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)
    var scroll_content_offset = gui.Vector2(x = 0.0, y = 0.0)
    var view = gui.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)

    let panel_pos_x = f32<-screen_width - panel_margin - panel_width
    let panel_pos_y = panel_margin
    let panel_rect = rl.Rectangle(
        x = panel_pos_x,
        y = panel_pos_y,
        width = panel_width,
        height = f32<-screen_height - 2.0 * panel_margin,
    )
    let canvas = rl.Rectangle(x = 0.0, y = 0.0, width = panel_pos_x, height = f32<-screen_height)
    let center = rl.Vector2(x = canvas.width / 2.0, y = canvas.height / 2.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var total_value: f32 = 0.0
        for index in range(0, slice_count):
            total_value += values[index]

        hovered_slice = -1
        let mouse_pos = rl.GetMousePosition()
        if rl.CheckCollisionPointRec(mouse_pos, canvas):
            let dx = mouse_pos.x - center.x
            let dy = mouse_pos.y - center.y
            let distance = math.sqrtf(dx * dx + dy * dy)

            if distance <= radius:
                var angle = math.atan2f(dy, dx) * rm.rad2deg
                if angle < 0.0:
                    angle = angle + f32<-360.0

                var current_angle: f32 = 0.0
                for index in range(0, slice_count):
                    let sweep = if total_value > 0.0 then values[index] / total_value * f32<-360.0 else f32<-0.0

                    if angle >= current_angle and angle < current_angle + sweep:
                        hovered_slice = index
                        break

                    current_angle = current_angle + sweep

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        var start_angle: f32 = 0.0
        for index in range(0, slice_count):
            let sweep_angle = if total_value > 0.0 then values[index] / total_value * f32<-360.0 else f32<-0.0
            let mid_angle = start_angle + sweep_angle / 2.0
            let color = rl.ColorFromHSV(f32<-index / f32<-slice_count * 360.0, 0.75, 0.9)
            var current_radius = radius

            if index == hovered_slice:
                current_radius = current_radius + f32<-20.0

            rl.DrawCircleSector(center, current_radius, start_angle, start_angle + sweep_angle, 120, color)

            if values[index] > 0.0:
                var label_text = empty_text
                if show_values and show_percentages:
                    label_text = rl.TextFormat(value_percent_format, values[index], values[index] / total_value * 100.0)
                elif show_values:
                    label_text = rl.TextFormat(value_only_format, values[index])
                elif show_percentages:
                    label_text = rl.TextFormat(percent_only_format, values[index] / total_value * 100.0)
                let text_size = rl.MeasureTextEx(rl.GetFontDefault(), label_text, 20.0, 1.0)
                let label_radius = radius * 0.7
                let label_pos = rl.Vector2(
                    x = center.x + math.cosf(mid_angle * rm.deg2rad) * label_radius - text_size.x / 2.0,
                    y = center.y + math.sinf(mid_angle * rm.deg2rad) * label_radius - text_size.y / 2.0,
                )
                rl.DrawText(label_text, i32<-label_pos.x, i32<-label_pos.y, 20, rl.WHITE)

            if show_donut:
                rl.DrawCircleV(center, donut_inner_radius, rl.RAYWHITE)

            start_angle = start_angle + sweep_angle

        rl.DrawRectangleRec(panel_rect, rl.Fade(rl.LIGHTGRAY, 0.5))
        rl.DrawRectangleLinesEx(panel_rect, 1.0, rl.GRAY)

        gui.GuiSpinner(gui.Rectangle(x = panel_pos_x + 95.0, y = panel_pos_y + 12.0, width = 125.0, height = 25.0), slices_text, raw(addr(slice_count)), 1, max_pie_slices, false)
        gui.GuiCheckBox(gui.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 52.0, width = 20.0, height = 20.0), show_values_text, raw(addr(show_values)))
        gui.GuiCheckBox(gui.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 82.0, width = 20.0, height = 20.0), show_percentages_text, raw(addr(show_percentages)))
        gui.GuiCheckBox(gui.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 112.0, width = 20.0, height = 20.0), make_donut_text, raw(addr(show_donut)))

        if show_donut:
            gui.GuiDisable()

        gui.GuiSliderBar(gui.Rectangle(x = panel_pos_x + 80.0, y = panel_pos_y + 142.0, width = panel_rect.width - 100.0, height = 30.0), inner_radius_text, empty_text, raw(addr(donut_inner_radius)), 5.0, radius - 10.0)
        gui.GuiEnable()

        gui.GuiLine(gui.Rectangle(x = panel_pos_x + 10.0, y = panel_pos_y + 182.0, width = panel_rect.width - 20.0, height = 1.0), empty_text)

        scroll_panel_bounds = gui.Rectangle(
            x = panel_pos_x + panel_margin,
            y = panel_pos_y + 202.0,
            width = panel_rect.width - panel_margin * 2.0,
            height = panel_rect.y + panel_rect.height - panel_pos_y + 202.0 - panel_margin,
        )
        let content_height = slice_count * 35

        gui.GuiScrollPanel(
            scroll_panel_bounds,
            empty_text,
            gui.Rectangle(x = 0.0, y = 0.0, width = panel_rect.width - 25.0, height = f32<-content_height),
            raw(addr(scroll_content_offset)),
            raw(addr(view)),
        )

        let content_x = view.x + scroll_content_offset.x
        let content_y = view.y + scroll_content_offset.y

        rl.BeginScissorMode(i32<-view.x, i32<-view.y, i32<-view.width, i32<-view.height)
        for index in range(0, slice_count):
            let row_y = i32<-(content_y + 5.0 + f32<-(index * 35))
            let color = rl.ColorFromHSV(f32<-index / f32<-slice_count * 360.0, 0.75, 0.9)
            rl.DrawRectangle(i32<-(content_x + 15.0), row_y + 5, 20, 20, color)

            if gui.GuiTextBox(gui.Rectangle(x = content_x + 45.0, y = f32<-row_y, width = 75.0, height = 30.0), raw(addr(labels[index][0])), 32, editing_label[index]) != 0:
                editing_label[index] = not editing_label[index]

            gui.GuiSliderBar(gui.Rectangle(x = content_x + 130.0, y = f32<-row_y, width = 110.0, height = 30.0), empty_text, empty_text, raw(addr(values[index])), 0.0, 1000.0)

        rl.EndScissorMode()

    return 0
