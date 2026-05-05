module examples.raylib.shapes.shapes_rectangle_advanced

import std.c.libm as math
import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.math as mt_math

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [shapes] example - rectangle advanced"


def emit_color(color: rl.Color) -> void:
    rlgl.rlColor4ub(color.r, color.g, color.b, color.a)


def emit_vertex(point: rl.Vector2) -> void:
    rlgl.rlVertex2f(point.x, point.y)


def emit_arc_vertex(center: rl.Vector2, angle: float, radius: float) -> void:
    rlgl.rlVertex2f(
        center.x + math.cosf(mt_math.deg2rad * angle) * radius,
        center.y + math.sinf(mt_math.deg2rad * angle) * radius,
    )


def draw_rectangle_rounded_gradient_h(rec: rl.Rectangle, roundness_left: float, roundness_right: float, segments: int, left: rl.Color, right: rl.Color) -> void:
    let not_rounded = roundness_left <= 0.0 and roundness_right <= 0.0
    if not_rounded or rec.width < 1.0 or rec.height < 1.0:
        rl.DrawRectangleGradientEx(rec, left, left, right, right)
        return

    var left_roundness = roundness_left
    var right_roundness = roundness_right
    if left_roundness >= 1.0:
        left_roundness = 1.0
    if right_roundness >= 1.0:
        right_roundness = 1.0

    let rec_size = if rec.width > rec.height: rec.height else: rec.width
    var radius_left = rec_size * left_roundness / 2.0
    var radius_right = rec_size * right_roundness / 2.0

    if radius_left <= 0.0:
        radius_left = 0.0
    if radius_right <= 0.0:
        radius_right = 0.0
    if radius_left <= 0.0 and radius_right <= 0.0:
        return

    let step_length = 90.0 / float<-segments

    let points = array[rl.Vector2, 12](
        rl.Vector2(x = rec.x + radius_left, y = rec.y),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y),
        rl.Vector2(x = rec.x + rec.width, y = rec.y + radius_right),
        rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height - radius_right),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + rec.height),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + rec.height),
        rl.Vector2(x = rec.x, y = rec.y + rec.height - radius_left),
        rl.Vector2(x = rec.x, y = rec.y + radius_left),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + radius_left),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + radius_right),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + rec.height - radius_right),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + rec.height - radius_left),
    )
    let centers = array[rl.Vector2, 4](points[8], points[9], points[10], points[11])
    let angles = array[float, 4](180.0, 270.0, 0.0, 90.0)

    rlgl.rlBegin(rlgl.RL_TRIANGLES)

    for corner_index in 0..4:
        var color = rl.Color(r = 0, g = 0, b = 0, a = 0)
        var radius: float = 0.0
        if corner_index == 0:
            color = left
            radius = radius_left
        elif corner_index == 1:
            color = right
            radius = radius_right
        elif corner_index == 2:
            color = right
            radius = radius_right
        else:
            color = left
            radius = radius_left

        var angle = angles[corner_index]
        let center = centers[corner_index]

        for _ in 0..segments:
            emit_color(color)
            emit_vertex(center)
            emit_arc_vertex(center, angle + step_length, radius)
            emit_arc_vertex(center, angle, radius)
            angle += step_length

    emit_color(left)
    emit_vertex(points[0])
    emit_vertex(points[8])
    emit_color(right)
    emit_vertex(points[9])
    emit_vertex(points[1])
    emit_color(left)
    emit_vertex(points[0])
    emit_color(right)
    emit_vertex(points[9])

    emit_color(right)
    emit_vertex(points[9])
    emit_vertex(points[10])
    emit_vertex(points[3])
    emit_vertex(points[2])
    emit_vertex(points[9])
    emit_vertex(points[3])

    emit_color(left)
    emit_vertex(points[11])
    emit_vertex(points[5])
    emit_color(right)
    emit_vertex(points[4])
    emit_vertex(points[10])
    emit_color(left)
    emit_vertex(points[11])
    emit_color(right)
    emit_vertex(points[4])

    emit_color(left)
    emit_vertex(points[7])
    emit_vertex(points[6])
    emit_vertex(points[11])
    emit_vertex(points[8])
    emit_vertex(points[7])
    emit_vertex(points[11])

    emit_color(left)
    emit_vertex(points[8])
    emit_vertex(points[11])
    emit_color(right)
    emit_vertex(points[10])
    emit_vertex(points[9])
    emit_color(left)
    emit_vertex(points[8])
    emit_color(right)
    emit_vertex(points[10])

    rlgl.rlEnd()


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let width = rl.GetScreenWidth() / 2.0
        let height = rl.GetScreenHeight() / 6.0
        var rec = rl.Rectangle(
            x = rl.GetScreenWidth() / 2.0 - width / 2.0,
            y = rl.GetScreenHeight() / 2.0 - 5.0 * (height / 2.0),
            width = width,
            height = height,
        )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        draw_rectangle_rounded_gradient_h(rec, 0.8, 0.8, 36, rl.BLUE, rl.RED)

        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 0.5, 1.0, 36, rl.RED, rl.PINK)

        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 1.0, 0.5, 36, rl.RED, rl.BLUE)

        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 0.0, 1.0, 36, rl.BLUE, rl.BLACK)

        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 1.0, 0.0, 36, rl.BLUE, rl.PINK)

    return 0
