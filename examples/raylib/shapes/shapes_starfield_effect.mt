module examples.raylib.shapes.shapes_starfield_effect

import std.c.raylib as rl
import std.raylib.math as mt_math

const screen_width: i32 = 800
const screen_height: i32 = 450
const star_count: i32 = 420
const window_title: cstr = c"raylib [shapes] example - starfield effect"
const speed_format: cstr = c"[MOUSE WHEEL] Current Speed: %.0f"
const mode_format: cstr = c"[SPACE] Current draw mode: %s"
const lines_text: cstr = c"Lines"
const circles_text: cstr = c"Circles"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let bg_color = rl.ColorLerp(rl.DARKBLUE, rl.BLACK, 0.69)

    var speed: f32 = 10.0 / 9.0
    var draw_lines = true
    var stars = zero[array[rl.Vector3, 420]]()
    var stars_screen_pos = zero[array[rl.Vector2, 420]]()

    for index in 0..star_count:
        stars[index].x = f32<-rl.GetRandomValue(-screen_width / 2, screen_width / 2)
        stars[index].y = f32<-rl.GetRandomValue(-screen_height / 2, screen_height / 2)
        stars[index].z = 1.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_move = rl.GetMouseWheelMove()
        if i32<-mouse_move != 0:
            speed += 2.0 * mouse_move / 9.0
        if speed < 0.0:
            speed = 0.1
        if speed > 2.0:
            speed = 2.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            draw_lines = not draw_lines

        let dt = rl.GetFrameTime()
        for index in 0..star_count:
            stars[index].z -= dt * speed

            stars_screen_pos[index] = rl.Vector2(
                x = screen_width * 0.5 + stars[index].x / stars[index].z,
                y = screen_height * 0.5 + stars[index].y / stars[index].z,
            )

            if stars[index].z < 0.0 or stars_screen_pos[index].x < 0.0 or stars_screen_pos[index].y < 0.0 or stars_screen_pos[index].x > screen_width or stars_screen_pos[index].y > screen_height:
                stars[index].x = f32<-rl.GetRandomValue(-screen_width / 2, screen_width / 2)
                stars[index].y = f32<-rl.GetRandomValue(-screen_height / 2, screen_height / 2)
                stars[index].z = 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(bg_color)

        for index in 0..star_count:
            if draw_lines:
                let t = mt_math.clamp(stars[index].z + 1.0 / 32.0, 0.0, 1.0)
                if t - stars[index].z > 0.001:
                    let start_pos = rl.Vector2(
                        x = screen_width * 0.5 + stars[index].x / t,
                        y = screen_height * 0.5 + stars[index].y / t,
                    )
                    rl.DrawLineV(start_pos, stars_screen_pos[index], rl.RAYWHITE)
            else:
                let radius = mt_math.lerp(stars[index].z, 1.0, 5.0)
                rl.DrawCircleV(stars_screen_pos[index], radius, rl.RAYWHITE)

        rl.DrawText(rl.TextFormat(speed_format, 9.0 * speed / 2.0), 10, 40, 20, rl.RAYWHITE)
        rl.DrawText(rl.TextFormat(mode_format, if draw_lines: lines_text else: circles_text), 10, 70, 20, rl.RAYWHITE)
        rl.DrawFPS(10, 10)

    return 0
