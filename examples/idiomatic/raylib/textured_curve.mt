module examples.idiomatic.raylib.textured_curve

import std.raylib as rl
import std.raylib.math as rm
import std.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const start_handle: i32 = 0
const start_tangent_handle: i32 = 1
const end_handle: i32 = 2
const end_tangent_handle: i32 = 3
const road_path: str = "../../raylib/resources/road.png"


def hovered_handle(mouse: rl.Vector2, curve_start_position: rl.Vector2, curve_start_position_tangent: rl.Vector2, curve_end_position: rl.Vector2, curve_end_position_tangent: rl.Vector2) -> i32:
    if rl.check_collision_point_circle(mouse, curve_start_position, 6.0):
        return start_handle
    if rl.check_collision_point_circle(mouse, curve_start_position_tangent, 6.0):
        return start_tangent_handle
    if rl.check_collision_point_circle(mouse, curve_end_position, 6.0):
        return end_handle
    if rl.check_collision_point_circle(mouse, curve_end_position_tangent, 6.0):
        return end_tangent_handle
    return -1


def draw_textured_curve(tex_road: rl.Texture2D, curve_start_position: rl.Vector2, curve_start_position_tangent: rl.Vector2, curve_end_position: rl.Vector2, curve_end_position_tangent: rl.Vector2, curve_width: f32, curve_segments: i32) -> void:
    let step = 1.0 / f32<-curve_segments

    var previous = curve_start_position
    var previous_tangent = rl.Vector2.zero()
    var previous_v: f32 = 0.0
    var tangent_set = false

    for index in 1..curve_segments + 1:
        let t = step * f32<-index
        let current = rl.get_spline_point_bezier_cubic(curve_start_position, curve_start_position_tangent, curve_end_position_tangent, curve_end_position, t)
        let delta = current.subtract(previous)
        let normal = rl.Vector2(x = -delta.y, y = delta.x).normalize()
        let v = previous_v + delta.length() / f32<-(tex_road.height * 2)

        if not tangent_set:
            previous_tangent = normal
            tangent_set = true

        let prev_pos_normal = previous.add(previous_tangent.scale(curve_width))
        let prev_neg_normal = previous.add(previous_tangent.scale(-curve_width))
        let current_pos_normal = current.add(normal.scale(curve_width))
        let current_neg_normal = current.add(normal.scale(-curve_width))

        rlgl.set_texture(tex_road.id)
        rlgl.begin(rlgl.RL_QUADS)
        rlgl.color_4ub(255, 255, 255, 255)
        rlgl.normal_3f(0.0, 0.0, 1.0)

        rlgl.tex_coord_2f(0.0, previous_v)
        rlgl.vertex_2f(prev_neg_normal.x, prev_neg_normal.y)
        rlgl.tex_coord_2f(1.0, previous_v)
        rlgl.vertex_2f(prev_pos_normal.x, prev_pos_normal.y)
        rlgl.tex_coord_2f(1.0, v)
        rlgl.vertex_2f(current_pos_normal.x, current_pos_normal.y)
        rlgl.tex_coord_2f(0.0, v)
        rlgl.vertex_2f(current_neg_normal.x, current_neg_normal.y)
        rlgl.end()

        previous = current
        previous_tangent = normal
        previous_v = v

    rlgl.set_texture(u32<-0)


def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_VSYNC_HINT | rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Textured Curve")
    defer rl.close_window()

    let tex_road = rl.load_texture(road_path)
    defer rl.unload_texture(tex_road)
    rl.set_texture_filter(tex_road, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var show_curve = false
    var curve_width: f32 = 50.0
    var curve_segments = 24
    var curve_start_position = rl.Vector2(x = 80.0, y = 100.0)
    var curve_start_position_tangent = rl.Vector2(x = 100.0, y = 300.0)
    var curve_end_position = rl.Vector2(x = 700.0, y = 350.0)
    var curve_end_position_tangent = rl.Vector2(x = 600.0, y = 100.0)
    var selected_handle = -1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            show_curve = not show_curve
        if rl.is_key_pressed(rl.KeyboardKey.KEY_EQUAL):
            curve_width += 2.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_MINUS):
            curve_width -= 2.0
        if curve_width < 2.0:
            curve_width = 2.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            curve_segments -= 2
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            curve_segments += 2
        if curve_segments < 2:
            curve_segments = 2

        let left_down = rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT)
        if not left_down:
            selected_handle = -1

        let mouse = rl.get_mouse_position()
        let hovered = hovered_handle(mouse, curve_start_position, curve_start_position_tangent, curve_end_position, curve_end_position_tangent)

        if left_down:
            if selected_handle >= 0:
                let mouse_delta = rl.get_mouse_delta()
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

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        draw_textured_curve(tex_road, curve_start_position, curve_start_position_tangent, curve_end_position, curve_end_position_tangent, curve_width, curve_segments)

        if show_curve:
            rl.draw_spline_segment_bezier_cubic(curve_start_position, curve_start_position_tangent, curve_end_position_tangent, curve_end_position, 2.0, rl.BLUE)

        rl.draw_line_v(curve_start_position, curve_start_position_tangent, rl.SKYBLUE)
        rl.draw_line_v(curve_start_position_tangent, curve_end_position_tangent, rl.fade(rl.LIGHTGRAY, 0.4))
        rl.draw_line_v(curve_end_position, curve_end_position_tangent, rl.PURPLE)

        if hovered == start_handle:
            rl.draw_circle_v(curve_start_position, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_start_position, 5.0, rl.RED)

        if hovered == start_tangent_handle:
            rl.draw_circle_v(curve_start_position_tangent, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_start_position_tangent, 5.0, rl.MAROON)

        if hovered == end_handle:
            rl.draw_circle_v(curve_end_position, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_end_position, 5.0, rl.GREEN)

        if hovered == end_tangent_handle:
            rl.draw_circle_v(curve_end_position_tangent, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_end_position_tangent, 5.0, rl.DARKGREEN)

        rl.draw_text("Drag points to move curve, press SPACE to show/hide base curve", 10, 10, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_f32("Curve width: %2.0f (Use + and - to adjust)", curve_width), 10, 30, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_i32("Curve segments: %d (Use LEFT and RIGHT to adjust)", curve_segments), 10, 50, 10, rl.DARKGRAY)

    return 0
