module examples.raylib.core.core_2d_camera_mouse_zoom

import std.c.libm as math
import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - 2d camera mouse zoom"
const mode_select_text: cstr = c"[1][2] Select mouse zoom mode (Wheel or Move)"
const wheel_zoom_text: cstr = c"Mouse left button drag to move, mouse wheel to zoom"
const move_zoom_text: cstr = c"Mouse left button drag to move, mouse press and move to zoom"

def clamp_zoom(zoom: f32) -> f32:
    if zoom < 0.125:
        return 0.125
    if zoom > 64.0:
        return 64.0
    return zoom

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = zero[rl.Camera2D]()
    camera.zoom = 1.0

    var zoom_mode = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            zoom_mode = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            zoom_mode = 1

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let delta = rl.GetMouseDelta()
            let scaled_delta = rl.Vector2(
                x = delta.x * (-1.0 / camera.zoom),
                y = delta.y * (-1.0 / camera.zoom),
            )
            camera.target = rl.Vector2(
                x = camera.target.x + scaled_delta.x,
                y = camera.target.y + scaled_delta.y,
            )

        if zoom_mode == 0:
            let wheel = rl.GetMouseWheelMove()
            if wheel != 0.0:
                let mouse_position = rl.GetMousePosition()
                let mouse_world_position = rl.GetScreenToWorld2D(mouse_position, camera)
                camera.offset = mouse_position
                camera.target = mouse_world_position

                let scale = 0.2 * wheel
                camera.zoom = clamp_zoom(math.expf(math.logf(camera.zoom) + scale))
        else:
            if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                let mouse_position = rl.GetMousePosition()
                let mouse_world_position = rl.GetScreenToWorld2D(mouse_position, camera)
                camera.offset = mouse_position
                camera.target = mouse_world_position

            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                let delta_x = rl.GetMouseDelta().x
                let scale = 0.005 * delta_x
                camera.zoom = clamp_zoom(math.expf(math.logf(camera.zoom) + scale))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode2D(camera)
        rlgl.rlPushMatrix()
        rlgl.rlTranslatef(0.0, 25.0 * 50.0, 0.0)
        rlgl.rlRotatef(90.0, 1.0, 0.0, 0.0)
        rl.DrawGrid(100, 50.0)
        rlgl.rlPopMatrix()
        rl.DrawCircle(screen_width / 2, screen_height / 2, 50.0, rl.MAROON)
        rl.EndMode2D()

        let mouse_position = rl.GetMousePosition()
        rl.DrawCircleV(mouse_position, 4.0, rl.DARKGRAY)
        rl.DrawTextEx(
            rl.GetFontDefault(),
            rl.TextFormat(c"[%i, %i]", rl.GetMouseX(), rl.GetMouseY()),
            rl.Vector2(x = mouse_position.x - 44.0, y = mouse_position.y - 24.0),
            20.0,
            2.0,
            rl.BLACK,
        )

        rl.DrawText(mode_select_text, 20, 20, 20, rl.DARKGRAY)
        rl.DrawText(if zoom_mode == 0: wheel_zoom_text else: move_zoom_text, 20, 50, 20, rl.DARKGRAY)

    return 0