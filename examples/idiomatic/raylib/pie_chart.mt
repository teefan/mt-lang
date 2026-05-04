module examples.idiomatic.raylib.pie_chart

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

const max_pie_slices: i32 = 10
const screen_width: i32 = 800
const screen_height: i32 = 450
const panel_width: f32 = 270.0
const panel_margin: f32 = 5.0
const radius: f32 = 205.0


def draw_slice_label(center: rl.Vector2, mid_angle: f32, label_text: cstr) -> void:
    let text_size = rl.measure_text_ex(rl.get_font_default(), label_text, 20.0, 1.0)
    let label_radius = radius * 0.7
    let label_pos = rl.Vector2(
        x = center.x + math.cos(mid_angle * math.deg2rad) * label_radius - text_size.x / 2.0,
        y = center.y + math.sin(mid_angle * math.deg2rad) * label_radius - text_size.y / 2.0,
    )
    rl.draw_text(label_text, i32<-label_pos.x, i32<-label_pos.y, 20, rl.WHITE)


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Pie Chart")
    defer rl.close_window()

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

    var labels = zero[array[str_builder[32], 10]]()
    labels[0].assign("Slice 01")
    labels[1].assign("Slice 02")
    labels[2].assign("Slice 03")
    labels[3].assign("Slice 04")
    labels[4].assign("Slice 05")
    labels[5].assign("Slice 06")
    labels[6].assign("Slice 07")
    labels[7].assign("Slice 08")
    labels[8].assign("Slice 09")
    labels[9].assign("Slice 10")
    var editing_label = zero[array[bool, 10]]()

    var show_values = true
    var show_percentages = false
    var show_donut = false
    var hovered_slice = -1
    var scroll_panel_bounds = rl.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)
    var scroll_content_offset = rl.Vector2(x = 0.0, y = 0.0)
    var view = rl.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)

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

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var total_value: f32 = 0.0
        for index in 0..slice_count:
            total_value += values[index]

        hovered_slice = -1
        let mouse_pos = rl.get_mouse_position()
        if rl.check_collision_point_rec(mouse_pos, canvas):
            let dx = mouse_pos.x - center.x
            let dy = mouse_pos.y - center.y
            let distance = math.sqrt(dx * dx + dy * dy)

            if distance <= radius:
                var angle = math.atan2(dy, dx) * math.rad2deg
                if angle < 0.0:
                    angle += f32<-360.0

                var current_angle: f32 = 0.0
                for index in 0..slice_count:
                    let sweep: f32 = if total_value > 0.0: values[index] / total_value * f32<-360.0 else: f32<-0.0
                    if angle >= current_angle and angle < current_angle + sweep:
                        hovered_slice = index
                        break

                    current_angle += sweep

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        var start_angle: f32 = 0.0
        for index in 0..slice_count:
            let sweep_angle: f32 = if total_value > 0.0: values[index] / total_value * f32<-360.0 else: f32<-0.0
            let mid_angle = start_angle + sweep_angle / 2.0
            let color = rl.color_from_hsv(f32<-index / f32<-slice_count * 360.0, 0.75, 0.9)
            var current_radius = radius
            if index == hovered_slice:
                current_radius += f32<-20.0

            rl.draw_circle_sector(center, current_radius, start_angle, start_angle + sweep_angle, 120, color)

            if values[index] > 0.0:
                if show_values and show_percentages:
                    draw_slice_label(center, mid_angle, rl.text_format_f32_f32("%.1f (%.0f%%)", values[index], values[index] / total_value * 100.0))
                elif show_values:
                    draw_slice_label(center, mid_angle, rl.text_format_f32("%.1f", values[index]))
                elif show_percentages:
                    draw_slice_label(center, mid_angle, rl.text_format_f32("%.0f%%", values[index] / total_value * 100.0))

            start_angle += sweep_angle

        if show_donut:
            rl.draw_circle_v(center, donut_inner_radius, rl.RAYWHITE)

        rl.draw_rectangle_rec(panel_rect, rl.fade(rl.LIGHTGRAY, 0.5))
        rl.draw_rectangle_lines_ex(panel_rect, 1.0, rl.GRAY)

        gui.spinner(rl.Rectangle(x = panel_pos_x + 95.0, y = panel_pos_y + 12.0, width = 125.0, height = 25.0), "Slices ", inout slice_count, 1, max_pie_slices, false)
        gui.check_box(rl.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 52.0, width = 20.0, height = 20.0), "Show Values", inout show_values)
        gui.check_box(rl.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 82.0, width = 20.0, height = 20.0), "Show Percentages", inout show_percentages)
        gui.check_box(rl.Rectangle(x = panel_pos_x + 20.0, y = panel_pos_y + 112.0, width = 20.0, height = 20.0), "Make Donut", inout show_donut)

        if show_donut:
            gui.disable()

        gui.slider_bar(rl.Rectangle(x = panel_pos_x + 80.0, y = panel_pos_y + 142.0, width = panel_rect.width - 100.0, height = 30.0), "Inner Radius", "", inout donut_inner_radius, 5.0, radius - 10.0)
        gui.enable()
        gui.line(rl.Rectangle(x = panel_pos_x + 10.0, y = panel_pos_y + 182.0, width = panel_rect.width - 20.0, height = 1.0), "")

        scroll_panel_bounds = rl.Rectangle(
            x = panel_pos_x + panel_margin,
            y = panel_pos_y + 202.0,
            width = panel_rect.width - panel_margin * 2.0,
            height = panel_rect.y + panel_rect.height - panel_pos_y + 202.0 - panel_margin,
        )
        let content_height = slice_count * 35

        gui.scroll_panel(
            scroll_panel_bounds,
            "",
            rl.Rectangle(x = 0.0, y = 0.0, width = panel_rect.width - 25.0, height = f32<-content_height),
            inout scroll_content_offset,
            out view,
        )

        let content_x = view.x + scroll_content_offset.x
        let content_y = view.y + scroll_content_offset.y

        rl.begin_scissor_mode(i32<-view.x, i32<-view.y, i32<-view.width, i32<-view.height)
        for index in 0..slice_count:
            let row_y = i32<-(content_y + 5.0 + f32<-(index * 35))
            let color = rl.color_from_hsv(f32<-index / f32<-slice_count * 360.0, 0.75, 0.9)
            rl.draw_rectangle(i32<-(content_x + 15.0), row_y + 5, 20, 20, color)

            if gui.text_box(rl.Rectangle(x = content_x + 45.0, y = f32<-row_y, width = 75.0, height = 30.0), labels[index], editing_label[index]) != 0:
                editing_label[index] = not editing_label[index]

            gui.slider_bar(rl.Rectangle(x = content_x + 130.0, y = f32<-row_y, width = 110.0, height = 30.0), "", "", inout values[index], 0.0, 1000.0)

        rl.end_scissor_mode()

    return 0
