module examples.raylib.shapes.shapes_bullet_hell

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math
import std.mem.heap as heap

struct Bullet:
    position: rl.Vector2
    acceleration: rl.Vector2
    disabled: bool
    color: rl.Color

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_bullets: i32 = 500000
const window_title: cstr = c"raylib [shapes] example - bullet hell"
const controls_title: cstr = c"Controls:"
const control_rows_text: cstr = c"- Right/Left or A/D: Change rows number"
const control_speed_text: cstr = c"- Up/Down or W/S: Change bullet speed"
const control_cooldown_text: cstr = c"- Z or X: Change spawn cooldown"
const control_angle_text: cstr = c"- Space (Hold): Change the angle increment"
const control_draw_text: cstr = c"- Enter: Switch draw method (Performance)"
const control_clear_text: cstr = c"- C: Clear bullets"
const draw_texture_text: cstr = c"Draw method: DrawTexture(*)"
const draw_circle_text: cstr = c"Draw method: DrawCircle(*)"
const status_format: cstr = c"[ FPS: %d, Bullets: %d, Rows: %d, Bullet speed: %.2f, Angle increment per frame: %d, Cooldown: %.0f ]"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let bullets = heap.alloc_zeroed[Bullet](cast[usize](max_bullets))
    defer heap.release(bullets)
    var bullets_view = span[Bullet](data = bullets, len = cast[usize](max_bullets))

    var bullet_count = 0
    var bullet_disabled_count = 0
    let bullet_radius = 10
    var bullet_speed: f32 = 3.0
    var bullet_rows = 6
    let bullet_colors = array[rl.Color, 2](rl.RED, rl.BLUE)

    var base_direction: f32 = 0.0
    var angle_increment = 5
    var spawn_cooldown: f32 = 2.0
    var spawn_cooldown_timer: f32 = spawn_cooldown
    var magic_circle_rotation: f32 = 0.0

    let bullet_texture = rl.LoadRenderTexture(24, 24)
    defer rl.UnloadRenderTexture(bullet_texture)

    rl.BeginTextureMode(bullet_texture)
    rl.DrawCircle(12, 12, cast[f32](bullet_radius), rl.WHITE)
    rl.DrawCircleLines(12, 12, cast[f32](bullet_radius), rl.BLACK)
    rl.EndTextureMode()

    var draw_in_performance_mode = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if bullet_count >= max_bullets:
            bullet_count = 0
            bullet_disabled_count = 0

        spawn_cooldown_timer -= 1.0
        if spawn_cooldown_timer < 0.0:
            spawn_cooldown_timer = spawn_cooldown

            let degrees_per_row = 360.0 / cast[f32](bullet_rows)
            for row in range(0, bullet_rows):
                if bullet_count < max_bullets:
                    bullets_view[bullet_count].position = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
                    bullets_view[bullet_count].disabled = false
                    bullets_view[bullet_count].color = bullet_colors[row % 2]

                    let bullet_direction = base_direction + degrees_per_row * cast[f32](row)
                    let radians = bullet_direction * mt_math.deg2rad
                    bullets_view[bullet_count].acceleration = rl.Vector2(
                        x = bullet_speed * math.cosf(radians),
                        y = bullet_speed * math.sinf(radians),
                    )

                    bullet_count += 1

            base_direction += cast[f32](angle_increment)

        for index in range(0, bullet_count):
            if not bullets_view[index].disabled:
                bullets_view[index].position.x += bullets_view[index].acceleration.x
                bullets_view[index].position.y += bullets_view[index].acceleration.y

                let out_of_bounds = bullets_view[index].position.x < -cast[f32](bullet_radius * 2) or bullets_view[index].position.x > cast[f32](screen_width + bullet_radius * 2) or bullets_view[index].position.y < -cast[f32](bullet_radius * 2) or bullets_view[index].position.y > cast[f32](screen_height + bullet_radius * 2)
                if out_of_bounds:
                    bullets_view[index].disabled = true
                    bullet_disabled_count += 1

        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT) or rl.IsKeyPressed(rl.KeyboardKey.KEY_D)) and bullet_rows < 359:
            bullet_rows += 1
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT) or rl.IsKeyPressed(rl.KeyboardKey.KEY_A)) and bullet_rows > 1:
            bullet_rows -= 1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP) or rl.IsKeyPressed(rl.KeyboardKey.KEY_W):
            bullet_speed += 0.25
        if (rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN) or rl.IsKeyPressed(rl.KeyboardKey.KEY_S)) and bullet_speed > 0.50:
            bullet_speed -= 0.25
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Z) and spawn_cooldown > 1.0:
            spawn_cooldown -= 1.0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_X):
            spawn_cooldown += 1.0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            draw_in_performance_mode = not draw_in_performance_mode

        if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE):
            angle_increment += 1
            angle_increment = angle_increment % 360

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
            bullet_count = 0
            bullet_disabled_count = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        magic_circle_rotation += 1.0
        rl.DrawRectanglePro(
            rl.Rectangle(x = screen_width / 2.0, y = screen_height / 2.0, width = 120.0, height = 120.0),
            rl.Vector2(x = 60.0, y = 60.0),
            magic_circle_rotation,
            rl.PURPLE,
        )
        rl.DrawRectanglePro(
            rl.Rectangle(x = screen_width / 2.0, y = screen_height / 2.0, width = 120.0, height = 120.0),
            rl.Vector2(x = 60.0, y = 60.0),
            magic_circle_rotation + 45.0,
            rl.PURPLE,
        )
        rl.DrawCircleLines(screen_width / 2, screen_height / 2, 70.0, rl.BLACK)
        rl.DrawCircleLines(screen_width / 2, screen_height / 2, 50.0, rl.BLACK)
        rl.DrawCircleLines(screen_width / 2, screen_height / 2, 30.0, rl.BLACK)

        if draw_in_performance_mode:
            for index in range(0, bullet_count):
                if not bullets_view[index].disabled:
                    rl.DrawTexture(
                        bullet_texture.texture,
                        cast[i32](bullets_view[index].position.x - cast[f32](bullet_texture.texture.width) * 0.5),
                        cast[i32](bullets_view[index].position.y - cast[f32](bullet_texture.texture.height) * 0.5),
                        bullets_view[index].color,
                    )
        else:
            for index in range(0, bullet_count):
                if not bullets_view[index].disabled:
                    rl.DrawCircleV(bullets_view[index].position, cast[f32](bullet_radius), bullets_view[index].color)
                    rl.DrawCircleLinesV(bullets_view[index].position, cast[f32](bullet_radius), rl.BLACK)

        let overlay_color = rl.Color(r = 0, g = 0, b = 0, a = 200)
        rl.DrawRectangle(10, 10, 280, 150, overlay_color)
        rl.DrawText(controls_title, 20, 20, 10, rl.LIGHTGRAY)
        rl.DrawText(control_rows_text, 40, 40, 10, rl.LIGHTGRAY)
        rl.DrawText(control_speed_text, 40, 60, 10, rl.LIGHTGRAY)
        rl.DrawText(control_cooldown_text, 40, 80, 10, rl.LIGHTGRAY)
        rl.DrawText(control_angle_text, 40, 100, 10, rl.LIGHTGRAY)
        rl.DrawText(control_draw_text, 40, 120, 10, rl.LIGHTGRAY)
        rl.DrawText(control_clear_text, 40, 140, 10, rl.LIGHTGRAY)

        rl.DrawRectangle(610, 10, 170, 30, overlay_color)
        if draw_in_performance_mode:
            rl.DrawText(draw_texture_text, 620, 20, 10, rl.GREEN)
        else:
            rl.DrawText(draw_circle_text, 620, 20, 10, rl.RED)

        rl.DrawRectangle(135, 410, 530, 30, overlay_color)
        rl.DrawText(
            rl.TextFormat(status_format, rl.GetFPS(), bullet_count - bullet_disabled_count, bullet_rows, bullet_speed, angle_increment, spawn_cooldown),
            155,
            420,
            10,
            rl.GREEN,
        )

    return 0
