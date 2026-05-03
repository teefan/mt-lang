module examples.raylib.shapes.shapes_collision_area

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const screen_upper_limit: i32 = 40
const window_title: cstr = c"raylib [shapes] example - collision area"
const collision_text: cstr = c"COLLISION!"
const collision_area_format: cstr = c"Collision Area: %i"
const pause_text: cstr = c"Press SPACE to PAUSE/RESUME"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var box_a = rl.Rectangle(
        x = 10.0,
        y = f32<-rl.GetScreenHeight() / 2.0 - 50.0,
        width = 200.0,
        height = 100.0,
    )
    var box_a_speed_x: f32 = 4.0
    var box_b = rl.Rectangle(
        x = f32<-rl.GetScreenWidth() / 2.0 - 30.0,
        y = f32<-rl.GetScreenHeight() / 2.0 - 30.0,
        width = 60.0,
        height = 60.0,
    )
    var box_collision = zero[rl.Rectangle]()
    var pause = false
    var collision = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if not pause:
            box_a.x += box_a_speed_x

        let screen_width_f = f32<-rl.GetScreenWidth()
        let screen_height_f = f32<-rl.GetScreenHeight()
        let screen_upper_limit_f = f32<-screen_upper_limit

        if box_a.x + box_a.width >= screen_width_f or box_a.x <= 0.0:
            box_a_speed_x *= -1.0

        box_b.x = f32<-rl.GetMouseX() - box_b.width / 2.0
        box_b.y = f32<-rl.GetMouseY() - box_b.height / 2.0

        if box_b.x + box_b.width >= screen_width_f:
            box_b.x = screen_width_f - box_b.width
        elif box_b.x <= 0.0:
            box_b.x = 0.0

        if box_b.y + box_b.height >= screen_height_f:
            box_b.y = screen_height_f - box_b.height
        elif box_b.y <= screen_upper_limit_f:
            box_b.y = screen_upper_limit_f

        collision = rl.CheckCollisionRecs(box_a, box_b)

        if collision:
            box_collision = rl.GetCollisionRec(box_a, box_b)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if collision:
            rl.DrawRectangle(0, 0, screen_width, screen_upper_limit, rl.RED)
        else:
            rl.DrawRectangle(0, 0, screen_width, screen_upper_limit, rl.BLACK)

        rl.DrawRectangleRec(box_a, rl.GOLD)
        rl.DrawRectangleRec(box_b, rl.BLUE)

        if collision:
            rl.DrawRectangleRec(box_collision, rl.LIME)
            rl.DrawText(collision_text, rl.GetScreenWidth() / 2 - rl.MeasureText(collision_text, 20) / 2, screen_upper_limit / 2 - 10, 20, rl.BLACK)
            let collision_area = i32<-box_collision.width * i32<-box_collision.height
            rl.DrawText(rl.TextFormat(collision_area_format, collision_area), rl.GetScreenWidth() / 2 - 100, screen_upper_limit + 10, 20, rl.BLACK)

        rl.DrawText(pause_text, 20, screen_height - 35, 20, rl.LIGHTGRAY)
        rl.DrawFPS(10, 10)

    return 0