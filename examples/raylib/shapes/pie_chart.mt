import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_PIE_SLICES: int = 10
const RAD_TO_DEG: float = 180.0 / rl.PI
const DEG_TO_RAD: float = rl.PI / 180.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - pie chart")
    defer rl.close_window()

    var slice_count = 7
    var donut_inner_radius: float = 25.0
    var values: array[float, MAX_PIE_SLICES] = array[float, MAX_PIE_SLICES](
        300.0,
        100.0,
        450.0,
        350.0,
        600.0,
        380.0,
        750.0,
        0.0,
        0.0,
        0.0
    )
    var labels: array[str_buffer[32], MAX_PIE_SLICES] = zero[array[str_buffer[32], MAX_PIE_SLICES]]
    var editing_label: array[bool, MAX_PIE_SLICES] = zero[array[bool, MAX_PIE_SLICES]]

    var index = 0
    while index < MAX_PIE_SLICES:
        labels[index].assign(text.cstr_as_str(rl.text_format("Slice %02i", index + 1)))
        index += 1

    var show_values = true
    var show_percentages = false
    var show_donut = false
    var hovered_slice = -1
    var scroll_panel_bounds: rl.Rectangle = zero[rl.Rectangle]
    var scroll_content_offset: rl.Vector2 = zero[rl.Vector2]
    var view: rl.Rectangle = zero[rl.Rectangle]

    let panel_width = 270
    let panel_margin = 5
    let panel_pos = rl.Vector2(
        x = float<-SCREEN_WIDTH - float<-panel_margin - float<-panel_width,
        y = float<-panel_margin
    )
    let panel_rect = rl.Rectangle(
        x = panel_pos.x,
        y = panel_pos.y,
        width = float<-panel_width,
        height = float<-SCREEN_HEIGHT - (2.0 * float<-panel_margin)
    )
    let canvas = rl.Rectangle(x = 0.0, y = 0.0, width = panel_pos.x, height = float<-SCREEN_HEIGHT)
    let center = rl.Vector2(x = canvas.width / 2.0, y = canvas.height / 2.0)
    let radius: float = 205.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var total_value: float = 0.0
        index = 0
        while index < slice_count:
            total_value += values[index]
            index += 1

        hovered_slice = -1
        let mouse_pos = rl.get_mouse_position()
        if rl.check_collision_point_rec(mouse_pos, canvas):
            let dx = mouse_pos.x - center.x
            let dy = mouse_pos.y - center.y
            let distance = float<-math.sqrt(double<-((dx * dx) + (dy * dy)))

            if distance <= radius:
                var angle: float = float<-(float<-math.atan2(double<-dy, double<-dx) * RAD_TO_DEG)
                if angle < 0.0:
                    angle = float<-(angle + 360.0)

                var current_angle: float = 0.0
                index = 0
                while index < slice_count:
                    let sweep: float = if total_value > 0.0: (values[index] / total_value) * 360.0 else: 0.0
                    if angle >= current_angle and angle < (current_angle + sweep):
                        hovered_slice = index
                        break
                    current_angle = float<-(current_angle + sweep)
                    index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var start_angle: float = 0.0
        index = 0
        while index < slice_count:
            let sweep_angle: float = if total_value > 0.0: (values[index] / total_value) * 360.0 else: 0.0
            let mid_angle = start_angle + sweep_angle / 2.0
            let color = rl.color_from_hsv((float<-index / float<-slice_count) * 360.0, 0.75, 0.9)
            var current_radius: float = radius
            if index == hovered_slice:
                current_radius = float<-(current_radius + 20.0)

            rl.draw_circle_sector(center, current_radius, start_angle, start_angle + sweep_angle, 120, color)

            if values[index] > 0.0:
                let percentage = if total_value > 0.0: (values[index] / total_value) * 100.0 else: 0.0
                var label_text = ""
                if show_values and show_percentages:
                    label_text = text.cstr_as_str(rl.text_format("%.1f (%.0f%%)", values[index], percentage))
                else if show_values:
                    label_text = text.cstr_as_str(rl.text_format("%.1f", values[index]))
                else if show_percentages:
                    label_text = text.cstr_as_str(rl.text_format("%.0f%%", percentage))

                if label_text.len != 0:
                    let text_size = rl.measure_text_ex(rl.get_font_default(), label_text, 20.0, 1.0)
                    let label_radius = radius * 0.7
                    let label_position = rl.Vector2(
                        x = float<-(center.x + float<-math.cos(double<-(mid_angle * DEG_TO_RAD)) * label_radius - text_size.x / 2.0),
                        y = float<-(center.y + float<-math.sin(double<-(mid_angle * DEG_TO_RAD)) * label_radius - text_size.y / 2.0)
                    )
                    rl.draw_text(label_text, int<-label_position.x, int<-label_position.y, 20, rl.WHITE)

            start_angle = float<-(start_angle + sweep_angle)
            index += 1

        if show_donut:
            rl.draw_circle_v(center, donut_inner_radius, rl.RAYWHITE)

        rl.draw_rectangle_rec(panel_rect, rl.fade(rl.LIGHTGRAY, 0.5))
        rl.draw_rectangle_lines_ex(panel_rect, 1.0, rl.GRAY)
        gui.spinner(
            rl.Rectangle(x = panel_pos.x + 95.0, y = panel_pos.y + 12.0, width = 125.0, height = 25.0),
            "Slices ",
            slice_count,
            1,
            MAX_PIE_SLICES,
            false
        )
        gui.check_box(
            rl.Rectangle(x = panel_pos.x + 20.0, y = panel_pos.y + 52.0, width = 20.0, height = 20.0),
            "Show Values",
            show_values
        )
        gui.check_box(
            rl.Rectangle(x = panel_pos.x + 20.0, y = panel_pos.y + 82.0, width = 20.0, height = 20.0),
            "Show Percentages",
            show_percentages
        )
        gui.check_box(
            rl.Rectangle(x = panel_pos.x + 20.0, y = panel_pos.y + 112.0, width = 20.0, height = 20.0),
            "Make Donut",
            show_donut
        )

        if not show_donut:
            gui.disable()
        gui.slider_bar(
            rl.Rectangle(
                x = panel_pos.x + 80.0,
                y = panel_pos.y + 142.0,
                width = panel_rect.width - 100.0,
                height = 30.0
            ),
            "Inner Radius",
            "",
            donut_inner_radius,
            5.0,
            radius - 10.0
        )
        gui.enable()

        gui.line(
            rl.Rectangle(
                x = panel_pos.x + 10.0,
                y = panel_pos.y + 182.0,
                width = panel_rect.width - 20.0,
                height = 1.0
            ),
            ""
        )

        scroll_panel_bounds = rl.Rectangle(
            x = panel_pos.x + float<-panel_margin,
            y = panel_pos.y + 202.0,
            width = panel_rect.width - (2.0 * float<-panel_margin),
            height = panel_rect.height - 202.0 - float<-panel_margin
        )
        let content_height = slice_count * 35
        gui.scroll_panel(
            scroll_panel_bounds,
            "",
            rl.Rectangle(x = 0.0, y = 0.0, width = panel_rect.width - 25.0, height = float<-content_height),
            scroll_content_offset,
            view
        )

        let content_x = view.x + scroll_content_offset.x
        let content_y = view.y + scroll_content_offset.y

        rl.begin_scissor_mode(int<-view.x, int<-view.y, int<-view.width, int<-view.height)

        index = 0
        while index < slice_count:
            let row_y = int<-(content_y + 5.0 + float<-index * 35.0)
            let color = rl.color_from_hsv((float<-index / float<-slice_count) * 360.0, 0.75, 0.9)
            rl.draw_rectangle(int<-(content_x + 15.0), row_y + 5, 20, 20, color)

            if gui.text_box(
                rl.Rectangle(x = content_x + 45.0, y = float<-row_y, width = 75.0, height = 30.0),
                labels[index],
                editing_label[index]
            ) != 0:
                editing_label[index] = not editing_label[index]

            gui.slider_bar(
                rl.Rectangle(x = content_x + 130.0, y = float<-row_y, width = 110.0, height = 30.0),
                "",
                "",
                values[index],
                0.0,
                1000.0
            )
            index += 1

        rl.end_scissor_mode()
        rl.end_drawing()

    return 0
