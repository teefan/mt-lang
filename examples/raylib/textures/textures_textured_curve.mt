module examples.raylib.textures.textures_textured_curve

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const screen_width: int = 800
const screen_height: int = 450
const start_handle: int = 0
const start_tangent_handle: int = 1
const end_handle: int = 2
const end_tangent_handle: int = 3
const window_title: cstr = c"raylib [textures] example - textured curve"
const road_path: cstr = c"../resources/road.png"
const help_text: cstr = c"Drag points to move curve, press SPACE to show/hide base curve"
const width_format: cstr = c"Curve width: %2.0f (Use + and - to adjust)"
const segments_format: cstr = c"Curve segments: %d (Use LEFT and RIGHT to adjust)"


def hovered_handle(mouse: rl.Vector2, curve_start_position: rl.Vector2, curve_start_position_tangent: rl.Vector2, curve_end_position: rl.Vector2, curve_end_position_tangent: rl.Vector2) -> int:
    if rl.CheckCollisionPointCircle(mouse, curve_start_position, 6.0):
        return start_handle
    if rl.CheckCollisionPointCircle(mouse, curve_start_position_tangent, 6.0):
        return start_tangent_handle
    if rl.CheckCollisionPointCircle(mouse, curve_end_position, 6.0):
        return end_handle
    if rl.CheckCollisionPointCircle(mouse, curve_end_position_tangent, 6.0):
        return end_tangent_handle
    return -1


def draw_textured_curve(tex_road: rl.Texture, curve_start_position: rl.Vector2, curve_start_position_tangent: rl.Vector2, curve_end_position: rl.Vector2, curve_end_position_tangent: rl.Vector2, curve_width: float, curve_segments: int) -> void:
    let step = 1.0 / float<-curve_segments

    var previous = curve_start_position
    var previous_tangent = rl.Vector2.zero()
    var previous_v: float = 0.0
    var tangent_set = false

    for index in 1..curve_segments + 1:
        let t = step * float<-index
        let current = rl.GetSplinePointBezierCubic(curve_start_position, curve_start_position_tangent, curve_end_position_tangent, curve_end_position, t)
        let delta = current.subtract(previous)
        let normal = rl.Vector2(x = -delta.y, y = delta.x).normalize()
        let v = previous_v + delta.length() / float<-(tex_road.height * 2)

        if not tangent_set:
            previous_tangent = normal
            tangent_set = true

        let prev_pos_normal = previous.add(previous_tangent.scale(curve_width))
        let prev_neg_normal = previous.add(previous_tangent.scale(-curve_width))
        let current_pos_normal = current.add(normal.scale(curve_width))
        let current_neg_normal = current.add(normal.scale(-curve_width))

        rlgl.rlSetTexture(tex_road.id)
        rlgl.rlBegin(rlgl.RL_QUADS)
        rlgl.rlColor4ub(255, 255, 255, 255)
        rlgl.rlNormal3f(0.0, 0.0, 1.0)

        rlgl.rlTexCoord2f(0.0, previous_v)
        rlgl.rlVertex2f(prev_neg_normal.x, prev_neg_normal.y)
        rlgl.rlTexCoord2f(1.0, previous_v)
        rlgl.rlVertex2f(prev_pos_normal.x, prev_pos_normal.y)
        rlgl.rlTexCoord2f(1.0, v)
        rlgl.rlVertex2f(current_pos_normal.x, current_pos_normal.y)
        rlgl.rlTexCoord2f(0.0, v)
        rlgl.rlVertex2f(current_neg_normal.x, current_neg_normal.y)
        rlgl.rlEnd()

        previous = current
        previous_tangent = normal
        previous_v = v

    rlgl.rlSetTexture(uint<-0)


def main() -> int:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_VSYNC_HINT | rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let tex_road = rl.LoadTexture(road_path)
    defer rl.UnloadTexture(tex_road)
    rl.SetTextureFilter(tex_road, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var show_curve = false
    var curve_width: float = 50.0
    var curve_segments = 24
    var curve_start_position = rl.Vector2(x = 80.0, y = 100.0)
    var curve_start_position_tangent = rl.Vector2(x = 100.0, y = 300.0)
    var curve_end_position = rl.Vector2(x = 700.0, y = 350.0)
    var curve_end_position_tangent = rl.Vector2(x = 600.0, y = 100.0)
    var selected_handle = -1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            show_curve = not show_curve
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_EQUAL):
            curve_width += 2.0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_MINUS):
            curve_width -= 2.0
        if curve_width < 2.0:
            curve_width = 2.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            curve_segments -= 2
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            curve_segments += 2
        if curve_segments < 2:
            curve_segments = 2

        let left_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)
        if not left_down:
            selected_handle = -1

        let mouse = rl.GetMousePosition()
        let hovered = hovered_handle(mouse, curve_start_position, curve_start_position_tangent, curve_end_position, curve_end_position_tangent)

        if left_down:
            if selected_handle >= 0:
                let mouse_delta = rl.GetMouseDelta()
                if selected_handle == start_handle:
                    curve_start_position = curve_start_position.add(mouse_delta)
                elif selected_handle == start_tangent_handle:
                    curve_start_position_tangent = curve_start_position_tangent.add(mouse_delta)
                elif selected_handle == end_handle:
                    curve_end_position = curve_end_position.add(mouse_delta)
                elif selected_handle == end_tangent_handle:
                    curve_end_position_tangent = curve_end_position_tangent.add(mouse_delta)
            else:
                selected_handle = hovered

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        draw_textured_curve(tex_road, curve_start_position, curve_start_position_tangent, curve_end_position, curve_end_position_tangent, curve_width, curve_segments)

        if show_curve:
            rl.DrawSplineSegmentBezierCubic(curve_start_position, curve_start_position_tangent, curve_end_position_tangent, curve_end_position, 2.0, rl.BLUE)

        rl.DrawLineV(curve_start_position, curve_start_position_tangent, rl.SKYBLUE)
        rl.DrawLineV(curve_start_position_tangent, curve_end_position_tangent, rl.Fade(rl.LIGHTGRAY, 0.4))
        rl.DrawLineV(curve_end_position, curve_end_position_tangent, rl.PURPLE)

        if hovered == start_handle:
            rl.DrawCircleV(curve_start_position, 7.0, rl.YELLOW)
        rl.DrawCircleV(curve_start_position, 5.0, rl.RED)

        if hovered == start_tangent_handle:
            rl.DrawCircleV(curve_start_position_tangent, 7.0, rl.YELLOW)
        rl.DrawCircleV(curve_start_position_tangent, 5.0, rl.MAROON)

        if hovered == end_handle:
            rl.DrawCircleV(curve_end_position, 7.0, rl.YELLOW)
        rl.DrawCircleV(curve_end_position, 5.0, rl.GREEN)

        if hovered == end_tangent_handle:
            rl.DrawCircleV(curve_end_position_tangent, 7.0, rl.YELLOW)
        rl.DrawCircleV(curve_end_position_tangent, 5.0, rl.DARKGREEN)

        rl.DrawText(help_text, 10, 10, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(width_format, curve_width), 10, 30, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(segments_format, curve_segments), 10, 50, 10, rl.DARKGRAY)

    return 0
