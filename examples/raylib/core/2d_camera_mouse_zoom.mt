import std.math as math
import std.raylib as rl
import std.raymath as raymath
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 2d camera mouse zoom")
    defer rl.close_window()

    var camera = rl.Camera2D(
        target = rl.Vector2(x = 0.0, y = 0.0),
        offset = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 1.0
    )
    var zoom_mode = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            zoom_mode = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            zoom_mode = 1

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var delta = rl.get_mouse_delta()
            delta = raymath.vector2_scale(delta, -1.0 / camera.zoom)
            camera.target = raymath.vector2_add(camera.target, delta)

        if zoom_mode == 0:
            let wheel = rl.get_mouse_wheel_move()
            if wheel != 0.0:
                let mouse_world_pos = rl.get_screen_to_world_2d(rl.get_mouse_position(), camera)
                camera.offset = rl.get_mouse_position()
                camera.target = mouse_world_pos

                let scale = double<-(0.2 * wheel)
                camera.zoom = raymath.clamp(float<-math.exp(math.log(double<-camera.zoom) + scale), 0.125, 64.0)
        else:
            if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                let mouse_world_pos = rl.get_screen_to_world_2d(rl.get_mouse_position(), camera)
                camera.offset = rl.get_mouse_position()
                camera.target = mouse_world_pos

            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                let delta_x = rl.get_mouse_delta().x
                let scale = double<-(0.005 * delta_x)
                camera.zoom = raymath.clamp(float<-math.exp(math.log(double<-camera.zoom) + scale), 0.125, 64.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_2d(camera)
        rlgl.push_matrix()
        rlgl.translatef(0.0, 25.0 * 50.0, 0.0)
        rlgl.rotatef(90.0, 1.0, 0.0, 0.0)
        rl.draw_grid(100, 50.0)
        rlgl.pop_matrix()

        rl.draw_circle(rl.get_screen_width() / 2, rl.get_screen_height() / 2, 50.0, rl.MAROON)
        rl.end_mode_2d()

        rl.draw_circle_v(rl.get_mouse_position(), 4.0, rl.DARKGRAY)
        rl.draw_text_ex(
            rl.get_font_default(),
            f"[#{rl.get_mouse_x()}, #{rl.get_mouse_y()}]",
            raymath.vector2_add(rl.get_mouse_position(), rl.Vector2(x = -44.0, y = -24.0)),
            20.0,
            2.0,
            rl.BLACK
        )

        rl.draw_text("[1][2] Select mouse zoom mode (Wheel or Move)", 20, 20, 20, rl.DARKGRAY)
        if zoom_mode == 0:
            rl.draw_text("Mouse left button drag to move, mouse wheel to zoom", 20, 50, 20, rl.DARKGRAY)
        else:
            rl.draw_text("Mouse left button drag to move, mouse press and move to zoom", 20, 50, 20, rl.DARKGRAY)

        rl.end_drawing()

    return 0
