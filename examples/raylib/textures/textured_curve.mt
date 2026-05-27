import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.rlgl as rlgl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SELECT_START_POINT: int = 0
const SELECT_START_TANGENT: int = 1
const SELECT_END_POINT: int = 2
const SELECT_END_TANGENT: int = 3


function draw_textured_curve(texture: rl.Texture2D, curve_start_position: rl.Vector2, curve_start_tangent: rl.Vector2, curve_end_position: rl.Vector2, curve_end_tangent: rl.Vector2, curve_width: float, curve_segments: int) -> void:
    let step = 1.0 / float<-curve_segments

    var previous = curve_start_position
    var previous_tangent = rl.Vector2(x = 0.0, y = 0.0)
    var previous_v = float<-0.0
    var tangent_set = false

    rlgl.set_texture(texture.id)

    var index = 1
    while index <= curve_segments:
        let t = step * float<-index
        let a = float<-math.pow(double<-(1.0 - t), 3.0)
        let b = float<-(3.0 * math.pow(double<-(1.0 - t), 2.0) * double<-t)
        let c = float<-(3.0 * double<-(1.0 - t) * math.pow(double<-t, 2.0))
        let d = float<-math.pow(double<-t, 3.0)

        let current = rl.Vector2(
            x = a * curve_start_position.x + b * curve_start_tangent.x + c * curve_end_tangent.x + d * curve_end_position.x,
            y = a * curve_start_position.y + b * curve_start_tangent.y + c * curve_end_tangent.y + d * curve_end_position.y,
        )
        let delta = rl.Vector2(x = current.x - previous.x, y = current.y - previous.y)
        let normal = rm.vector2_normalize(rl.Vector2(x = -delta.y, y = delta.x))
        let v = previous_v + (rm.vector2_length(delta) / float<-(texture.height * 2))

        if not tangent_set:
            previous_tangent = normal
            tangent_set = true

        let prev_pos_normal = rm.vector2_add(previous, rm.vector2_scale(previous_tangent, curve_width))
        let prev_neg_normal = rm.vector2_add(previous, rm.vector2_scale(previous_tangent, -curve_width))
        let current_pos_normal = rm.vector2_add(current, rm.vector2_scale(normal, curve_width))
        let current_neg_normal = rm.vector2_add(current, rm.vector2_scale(normal, -curve_width))

        rlgl.begin(rlgl.RL_QUADS)
        rlgl.color4ub(255, 255, 255, 255)
        rlgl.normal3f(0.0, 0.0, 1.0)
        rlgl.tex_coord2f(0.0, previous_v)
        rlgl.vertex2f(prev_neg_normal.x, prev_neg_normal.y)
        rlgl.tex_coord2f(1.0, previous_v)
        rlgl.vertex2f(prev_pos_normal.x, prev_pos_normal.y)
        rlgl.tex_coord2f(1.0, v)
        rlgl.vertex2f(current_pos_normal.x, current_pos_normal.y)
        rlgl.tex_coord2f(0.0, v)
        rlgl.vertex2f(current_neg_normal.x, current_neg_normal.y)
        rlgl.end()

        previous = current
        previous_tangent = normal
        previous_v = v
        index += 1

    rlgl.set_texture(0)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_VSYNC_HINT | rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - textured curve")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let road_texture = rl.load_texture("road.png")
    defer rl.unload_texture(road_texture)
    rl.set_texture_filter(road_texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var show_curve = false
    var curve_width = float<-50.0
    var curve_segments = 24
    var curve_start_position = rl.Vector2(x = 80.0, y = 100.0)
    var curve_start_position_tangent = rl.Vector2(x = 100.0, y = 300.0)
    var curve_end_position = rl.Vector2(x = 700.0, y = 350.0)
    var curve_end_position_tangent = rl.Vector2(x = 600.0, y = 100.0)
    var selected_point = -1

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

        if not rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            selected_point = -1

        if selected_point != -1:
            let mouse_delta = rl.get_mouse_delta()
            if selected_point == SELECT_START_POINT:
                curve_start_position = rm.vector2_add(curve_start_position, mouse_delta)
            else if selected_point == SELECT_START_TANGENT:
                curve_start_position_tangent = rm.vector2_add(curve_start_position_tangent, mouse_delta)
            else if selected_point == SELECT_END_POINT:
                curve_end_position = rm.vector2_add(curve_end_position, mouse_delta)
            else if selected_point == SELECT_END_TANGENT:
                curve_end_position_tangent = rm.vector2_add(curve_end_position_tangent, mouse_delta)

        let mouse = rl.get_mouse_position()
        if selected_point == -1 and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if rl.check_collision_point_circle(mouse, curve_start_position, 6.0):
                selected_point = SELECT_START_POINT
            else if rl.check_collision_point_circle(mouse, curve_start_position_tangent, 6.0):
                selected_point = SELECT_START_TANGENT
            else if rl.check_collision_point_circle(mouse, curve_end_position, 6.0):
                selected_point = SELECT_END_POINT
            else if rl.check_collision_point_circle(mouse, curve_end_position_tangent, 6.0):
                selected_point = SELECT_END_TANGENT

        let curve_width_text = rl.text_format("Curve width: %2.0f (Use + and - to adjust)", curve_width)
        let curve_segments_text = rl.text_format("Curve segments: %d (Use LEFT and RIGHT to adjust)", curve_segments)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        draw_textured_curve(
            road_texture,
            curve_start_position,
            curve_start_position_tangent,
            curve_end_position,
            curve_end_position_tangent,
            curve_width,
            curve_segments,
        )

        if show_curve:
            rl.draw_spline_segment_bezier_cubic(
                curve_start_position,
                curve_end_position,
                curve_start_position_tangent,
                curve_end_position_tangent,
                2.0,
                rl.BLUE,
            )

        rl.draw_line_v(curve_start_position, curve_start_position_tangent, rl.SKYBLUE)
        rl.draw_line_v(curve_start_position_tangent, curve_end_position_tangent, rl.fade(rl.LIGHTGRAY, 0.4))
        rl.draw_line_v(curve_end_position, curve_end_position_tangent, rl.PURPLE)

        if rl.check_collision_point_circle(mouse, curve_start_position, 6.0):
            rl.draw_circle_v(curve_start_position, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_start_position, 5.0, rl.RED)

        if rl.check_collision_point_circle(mouse, curve_start_position_tangent, 6.0):
            rl.draw_circle_v(curve_start_position_tangent, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_start_position_tangent, 5.0, rl.MAROON)

        if rl.check_collision_point_circle(mouse, curve_end_position, 6.0):
            rl.draw_circle_v(curve_end_position, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_end_position, 5.0, rl.GREEN)

        if rl.check_collision_point_circle(mouse, curve_end_position_tangent, 6.0):
            rl.draw_circle_v(curve_end_position_tangent, 7.0, rl.YELLOW)
        rl.draw_circle_v(curve_end_position_tangent, 5.0, rl.DARKGREEN)

        rl.draw_text("Drag points to move curve, press SPACE to show/hide base curve", 10, 10, 10, rl.DARKGRAY)
        rl.draw_text(curve_width_text, 10, 30, 10, rl.DARKGRAY)
        rl.draw_text(curve_segments_text, 10, 50, 10, rl.DARKGRAY)

        rl.end_drawing()

    return 0
