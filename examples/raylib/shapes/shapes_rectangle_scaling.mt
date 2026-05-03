module examples.raylib.shapes.shapes_rectangle_scaling

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const mouse_scale_mark_size: f32 = 12.0
const window_title: cstr = c"raylib [shapes] example - rectangle scaling"
const help_text: cstr = c"Scale rectangle dragging from bottom-right corner!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var rec = rl.Rectangle(x = 100.0, y = 100.0, width = 200.0, height = 80.0)
    var mouse_position = zero[rl.Vector2]()
    var mouse_scale_ready = false
    var mouse_scale_mode = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        mouse_position = rl.GetMousePosition()

        let scale_handle = rl.Rectangle(
            x = rec.x + rec.width - mouse_scale_mark_size,
            y = rec.y + rec.height - mouse_scale_mark_size,
            width = mouse_scale_mark_size,
            height = mouse_scale_mark_size,
        )

        if rl.CheckCollisionPointRec(mouse_position, scale_handle):
            mouse_scale_ready = true
            if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_scale_mode = true
        else:
            mouse_scale_ready = false

        if mouse_scale_mode:
            mouse_scale_ready = true

            rec.width = mouse_position.x - rec.x
            rec.height = mouse_position.y - rec.y

            if rec.width < mouse_scale_mark_size:
                rec.width = mouse_scale_mark_size
            if rec.height < mouse_scale_mark_size:
                rec.height = mouse_scale_mark_size

            let screen_width_f = f32<-rl.GetScreenWidth()
            let screen_height_f = f32<-rl.GetScreenHeight()

            if rec.width > screen_width_f - rec.x:
                rec.width = screen_width_f - rec.x
            if rec.height > screen_height_f - rec.y:
                rec.height = screen_height_f - rec.y

            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                mouse_scale_mode = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(help_text, 10, 10, 20, rl.GRAY)
        rl.DrawRectangleRec(rec, rl.Fade(rl.GREEN, 0.5))

        if mouse_scale_ready:
            rl.DrawRectangleLinesEx(rec, 1.0, rl.RED)
            rl.DrawTriangle(
                rl.Vector2(x = rec.x + rec.width - mouse_scale_mark_size, y = rec.y + rec.height),
                rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height),
                rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height - mouse_scale_mark_size),
                rl.RED,
            )

    return 0
