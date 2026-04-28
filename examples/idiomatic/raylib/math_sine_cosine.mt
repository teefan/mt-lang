module examples.idiomatic.raylib.math_sine_cosine

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450
const wave_points: i32 = 36

def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Math Sine Cosine")
    defer rl.close_window()

    var sine_points = zero[array[rl.Vector2, 36]]()
    var cos_points = zero[array[rl.Vector2, 36]]()
    let center = rl.Vector2(x = screen_width / 2.0 - 30.0, y = screen_height / 2.0)
    let start = rl.Rectangle(x = 20.0, y = screen_height - 120.0, width = 200.0, height = 100.0)
    let half_wave_height = start.height / 2.0
    let radius: f32 = 130.0
    var angle: f32 = 0.0
    var pause = false

    for index in range(0, wave_points):
        let t = cast[f32](index) / cast[f32](wave_points - 1)
        let current_angle = t * 360.0 * math.deg2rad
        sine_points[index] = rl.Vector2(
            x = start.x + t * start.width,
            y = start.y + half_wave_height - math.sin(current_angle) * half_wave_height,
        )
        cos_points[index] = rl.Vector2(
            x = start.x + t * start.width,
            y = start.y + half_wave_height - math.cos(current_angle) * half_wave_height,
        )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let angle_rad: f32 = angle * math.deg2rad
        let cos_rad: f32 = math.cos(angle_rad)
        let sin_rad: f32 = math.sin(angle_rad)

        let point = rl.Vector2(x = center.x + cos_rad * radius, y = center.y - sin_rad * radius)
        let limit_min = rl.Vector2(x = center.x - radius, y = center.y - radius)
        let limit_max = rl.Vector2(x = center.x + radius, y = center.y + radius)

        let complementary: f32 = 90.0 - angle
        let supplementary: f32 = 180.0 - angle
        let explementary: f32 = 360.0 - angle

        let tangent: f32 = math.clamp(math.tan(angle_rad), -10.0, 10.0)
        let cotangent: f32 = if math.abs(tangent) > 0.001 then math.clamp(1.0 / tangent, -radius, radius) else 0.0
        let tangent_point = rl.Vector2(x = center.x + radius, y = center.y - tangent * radius)
        let cotangent_point = rl.Vector2(x = center.x + cotangent * radius, y = center.y - radius)

        if not pause:
            angle += 1.0
            if angle >= 360.0:
                angle = 0.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_line_ex(rl.Vector2(x = center.x, y = limit_min.y), rl.Vector2(x = cotangent_point.x, y = limit_min.y), 2.0, rl.ORANGE)
        rl.draw_line_dashed(center, cotangent_point, 10, 4, rl.ORANGE)

        rl.draw_line(580, 0, 580, rl.get_screen_height(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.draw_rectangle(580, 0, rl.get_screen_width(), rl.get_screen_height(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        rl.draw_circle_lines_v(center, radius, rl.GRAY)
        rl.draw_line_ex(rl.Vector2(x = center.x, y = limit_min.y), rl.Vector2(x = center.x, y = limit_max.y), 1.0, rl.GRAY)
        rl.draw_line_ex(rl.Vector2(x = limit_min.x, y = center.y), rl.Vector2(x = limit_max.x, y = center.y), 1.0, rl.GRAY)

        rl.draw_line_ex(rl.Vector2(x = start.x, y = start.y), rl.Vector2(x = start.x, y = start.y + start.height), 2.0, rl.GRAY)
        rl.draw_line_ex(rl.Vector2(x = start.x + start.width, y = start.y), rl.Vector2(x = start.x + start.width, y = start.y + start.height), 2.0, rl.GRAY)
        rl.draw_line_ex(rl.Vector2(x = start.x, y = start.y + half_wave_height), rl.Vector2(x = start.x + start.width, y = start.y + half_wave_height), 2.0, rl.GRAY)

        rl.draw_text("1", cast[i32](start.x) - 8, cast[i32](start.y), 6, rl.GRAY)
        rl.draw_text("0", cast[i32](start.x) - 8, cast[i32](start.y + half_wave_height) - 6, 6, rl.GRAY)
        rl.draw_text("-1", cast[i32](start.x) - 12, cast[i32](start.y + start.height) - 8, 6, rl.GRAY)
        rl.draw_text("0", cast[i32](start.x) - 2, cast[i32](start.y + start.height) + 4, 6, rl.GRAY)
        rl.draw_text("360", cast[i32](start.x + start.width) - 8, cast[i32](start.y + start.height) + 4, 6, rl.GRAY)

        rl.draw_line_ex(rl.Vector2(x = center.x, y = center.y), rl.Vector2(x = center.x, y = point.y), 2.0, rl.RED)
        rl.draw_line_dashed(rl.Vector2(x = point.x, y = center.y), rl.Vector2(x = point.x, y = point.y), 10, 4, rl.RED)
        rl.draw_text(rl.text_format_f32("Sine %.2f", sin_rad), 640, 190, 6, rl.RED)
        rl.draw_circle_v(rl.Vector2(x = start.x + angle / 360.0 * start.width, y = start.y + (-sin_rad + 1.0) * half_wave_height), 4.0, rl.RED)
        rl.draw_spline_linear(sine_points, 1.0, rl.RED)

        rl.draw_line_ex(rl.Vector2(x = center.x, y = center.y), rl.Vector2(x = point.x, y = center.y), 2.0, rl.BLUE)
        rl.draw_line_dashed(rl.Vector2(x = center.x, y = point.y), rl.Vector2(x = point.x, y = point.y), 10, 4, rl.BLUE)
        rl.draw_text(rl.text_format_f32("Cosine %.2f", cos_rad), 640, 210, 6, rl.BLUE)
        rl.draw_circle_v(rl.Vector2(x = start.x + angle / 360.0 * start.width, y = start.y + (-cos_rad + 1.0) * half_wave_height), 4.0, rl.BLUE)
        rl.draw_spline_linear(cos_points, 1.0, rl.BLUE)

        rl.draw_line_ex(rl.Vector2(x = limit_max.x, y = center.y), rl.Vector2(x = limit_max.x, y = tangent_point.y), 2.0, rl.PURPLE)
        rl.draw_line_dashed(center, tangent_point, 10, 4, rl.PURPLE)
        rl.draw_text(rl.text_format_f32("Tangent %.2f", tangent), 640, 230, 6, rl.PURPLE)
        rl.draw_text(rl.text_format_f32("Cotangent %.2f", cotangent), 640, 250, 6, rl.ORANGE)

        rl.draw_circle_sector_lines(center, radius * 0.6, -angle, -90.0, 36, rl.BEIGE)
        rl.draw_text(rl.text_format_f32("Complementary  %.0f deg", complementary), 640, 150, 6, rl.BEIGE)
        rl.draw_circle_sector_lines(center, radius * 0.5, -angle, -180.0, 36, rl.DARKBLUE)
        rl.draw_text(rl.text_format_f32("Supplementary  %.0f deg", supplementary), 640, 130, 6, rl.DARKBLUE)
        rl.draw_circle_sector_lines(center, radius * 0.4, -angle, -360.0, 36, rl.PINK)
        rl.draw_text(rl.text_format_f32("Explementary  %.0f deg", explementary), 640, 170, 6, rl.PINK)

        rl.draw_circle_sector_lines(center, radius * 0.7, -angle, 0.0, 36, rl.LIME)
        rl.draw_line_ex(rl.Vector2(x = center.x, y = center.y), point, 2.0, rl.BLACK)
        rl.draw_circle_v(point, 4.0, rl.BLACK)

        gui.toggle(rl.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), "Pause", inout pause)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), "Angle", rl.text_format_f32("%.0f deg", angle), inout angle, 0.0, 360.0)
        gui.group_box(rl.Rectangle(x = 620.0, y = 110.0, width = 140.0, height = 170.0), "Angle Values")
        rl.draw_fps(10, 10)

    return 0
