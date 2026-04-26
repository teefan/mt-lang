module examples.raylib.shapes.shapes_math_sine_cosine

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const wave_points: i32 = 36
const window_title: cstr = c"raylib [shapes] example - math sine cosine"
const pause_text: cstr = c"Pause"
const angle_text: cstr = c"Angle"
const angle_values_text: cstr = c"Angle Values"
const sine_format: cstr = c"Sine %.2f"
const cosine_format: cstr = c"Cosine %.2f"
const tangent_format: cstr = c"Tangent %.2f"
const cotangent_format: cstr = c"Cotangent %.2f"
const complementary_format: cstr = c"Complementary  %.0f deg"
const supplementary_format: cstr = c"Supplementary  %.0f deg"
const explementary_format: cstr = c"Explementary  %.0f deg"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var sine_points = zero[array[rl.Vector2, 36]]()
    var cos_points = zero[array[rl.Vector2, 36]]()
    let center = rl.Vector2(x = screen_width / 2.0 - 30.0, y = screen_height / 2.0)
    let start = rl.Rectangle(x = 20.0, y = screen_height - 120.0, width = 200.0, height = 100.0)
    let half_wave_height = start.height / 2.0
    var radius: f32 = 130.0
    var angle: f32 = 0.0
    var pause = false

    for index in range(0, wave_points):
        let t = cast[f32](index) / cast[f32](wave_points - 1)
        let current_angle = t * 360.0 * rm.deg2rad
        sine_points[index] = rl.Vector2(
            x = start.x + t * start.width,
            y = start.y + half_wave_height - math.sinf(current_angle) * half_wave_height,
        )
        cos_points[index] = rl.Vector2(
            x = start.x + t * start.width,
            y = start.y + half_wave_height - math.cosf(current_angle) * half_wave_height,
        )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let angle_rad = angle * rm.deg2rad
        let cos_rad = math.cosf(angle_rad)
        let sin_rad = math.sinf(angle_rad)

        let point = rl.Vector2(x = center.x + cos_rad * radius, y = center.y - sin_rad * radius)
        let limit_min = rl.Vector2(x = center.x - radius, y = center.y - radius)
        let limit_max = rl.Vector2(x = center.x + radius, y = center.y + radius)

        let complementary = 90.0 - angle
        let supplementary = 180.0 - angle
        let explementary = 360.0 - angle

        let tangent = rm.clamp(math.tanf(angle_rad), -10.0, 10.0)
        let cotangent = if math.fabsf(tangent) > 0.001 then rm.clamp(1.0 / tangent, -radius, radius) else 0.0
        let tangent_point = rl.Vector2(x = center.x + radius, y = center.y - tangent * radius)
        let cotangent_point = rl.Vector2(x = center.x + cotangent * radius, y = center.y - radius)

        if not pause:
            angle += 1.0
            if angle >= 360.0:
                angle = 0.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawLineEx(rl.Vector2(x = center.x, y = limit_min.y), rl.Vector2(x = cotangent_point.x, y = limit_min.y), 2.0, rl.ORANGE)
        rl.DrawLineDashed(center, cotangent_point, 10, 4, rl.ORANGE)

        rl.DrawLine(580, 0, 580, rl.GetScreenHeight(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.DrawRectangle(580, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        rl.DrawCircleLinesV(center, radius, rl.GRAY)
        rl.DrawLineEx(rl.Vector2(x = center.x, y = limit_min.y), rl.Vector2(x = center.x, y = limit_max.y), 1.0, rl.GRAY)
        rl.DrawLineEx(rl.Vector2(x = limit_min.x, y = center.y), rl.Vector2(x = limit_max.x, y = center.y), 1.0, rl.GRAY)

        rl.DrawLineEx(rl.Vector2(x = start.x, y = start.y), rl.Vector2(x = start.x, y = start.y + start.height), 2.0, rl.GRAY)
        rl.DrawLineEx(rl.Vector2(x = start.x + start.width, y = start.y), rl.Vector2(x = start.x + start.width, y = start.y + start.height), 2.0, rl.GRAY)
        rl.DrawLineEx(rl.Vector2(x = start.x, y = start.y + half_wave_height), rl.Vector2(x = start.x + start.width, y = start.y + half_wave_height), 2.0, rl.GRAY)

        rl.DrawText(c"1", cast[i32](start.x) - 8, cast[i32](start.y), 6, rl.GRAY)
        rl.DrawText(c"0", cast[i32](start.x) - 8, cast[i32](start.y + half_wave_height) - 6, 6, rl.GRAY)
        rl.DrawText(c"-1", cast[i32](start.x) - 12, cast[i32](start.y + start.height) - 8, 6, rl.GRAY)
        rl.DrawText(c"0", cast[i32](start.x) - 2, cast[i32](start.y + start.height) + 4, 6, rl.GRAY)
        rl.DrawText(c"360", cast[i32](start.x + start.width) - 8, cast[i32](start.y + start.height) + 4, 6, rl.GRAY)

        rl.DrawLineEx(rl.Vector2(x = center.x, y = center.y), rl.Vector2(x = center.x, y = point.y), 2.0, rl.RED)
        rl.DrawLineDashed(rl.Vector2(x = point.x, y = center.y), rl.Vector2(x = point.x, y = point.y), 10, 4, rl.RED)
        rl.DrawText(rl.TextFormat(sine_format, sin_rad), 640, 190, 6, rl.RED)
        rl.DrawCircleV(rl.Vector2(x = start.x + angle / 360.0 * start.width, y = start.y + (-sin_rad + 1.0) * half_wave_height), 4.0, rl.RED)
        rl.DrawSplineLinear(raw(addr(sine_points[0])), wave_points, 1.0, rl.RED)

        rl.DrawLineEx(rl.Vector2(x = center.x, y = center.y), rl.Vector2(x = point.x, y = center.y), 2.0, rl.BLUE)
        rl.DrawLineDashed(rl.Vector2(x = center.x, y = point.y), rl.Vector2(x = point.x, y = point.y), 10, 4, rl.BLUE)
        rl.DrawText(rl.TextFormat(cosine_format, cos_rad), 640, 210, 6, rl.BLUE)
        rl.DrawCircleV(rl.Vector2(x = start.x + angle / 360.0 * start.width, y = start.y + (-cos_rad + 1.0) * half_wave_height), 4.0, rl.BLUE)
        rl.DrawSplineLinear(raw(addr(cos_points[0])), wave_points, 1.0, rl.BLUE)

        rl.DrawLineEx(rl.Vector2(x = limit_max.x, y = center.y), rl.Vector2(x = limit_max.x, y = tangent_point.y), 2.0, rl.PURPLE)
        rl.DrawLineDashed(center, tangent_point, 10, 4, rl.PURPLE)
        rl.DrawText(rl.TextFormat(tangent_format, tangent), 640, 230, 6, rl.PURPLE)

        rl.DrawText(rl.TextFormat(cotangent_format, cotangent), 640, 250, 6, rl.ORANGE)

        rl.DrawCircleSectorLines(center, radius * 0.6, -angle, -90.0, 36, rl.BEIGE)
        rl.DrawText(rl.TextFormat(complementary_format, complementary), 640, 150, 6, rl.BEIGE)

        rl.DrawCircleSectorLines(center, radius * 0.5, -angle, -180.0, 36, rl.DARKBLUE)
        rl.DrawText(rl.TextFormat(supplementary_format, supplementary), 640, 130, 6, rl.DARKBLUE)

        rl.DrawCircleSectorLines(center, radius * 0.4, -angle, -360.0, 36, rl.PINK)
        rl.DrawText(rl.TextFormat(explementary_format, explementary), 640, 170, 6, rl.PINK)

        rl.DrawCircleSectorLines(center, radius * 0.7, -angle, 0.0, 36, rl.LIME)
        rl.DrawLineEx(rl.Vector2(x = center.x, y = center.y), point, 2.0, rl.BLACK)
        rl.DrawCircleV(point, 4.0, rl.BLACK)

        gui.GuiSetStyle(gui.GuiControl.LABEL, gui.GuiControlProperty.TEXT_COLOR_NORMAL, rl.ColorToInt(rl.GRAY))
        gui.GuiToggle(gui.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), pause_text, raw(addr(pause)))
        gui.GuiSetStyle(gui.GuiControl.LABEL, gui.GuiControlProperty.TEXT_COLOR_NORMAL, rl.ColorToInt(rl.LIME))
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), angle_text, rl.TextFormat(c"%.0f deg", angle), raw(addr(angle)), 0.0, 360.0)
        gui.GuiGroupBox(gui.Rectangle(x = 620.0, y = 110.0, width = 140.0, height = 170.0), angle_values_text)

        rl.DrawFPS(10, 10)

    return 0
