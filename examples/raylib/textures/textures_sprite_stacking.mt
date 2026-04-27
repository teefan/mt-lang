module examples.raylib.textures.textures_sprite_stacking

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const stack_count: i32 = 122
const window_title: cstr = c"raylib [textures] example - sprite stacking"
const booth_path: cstr = c"resources/booth.png"
const help_text: cstr = c"A/D to spin\nmouse wheel to change separation (aka 'angle')"
const credit_text: cstr = c"redbooth model (c) kluchek under cc 4.0"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let booth = rl.LoadTexture(booth_path)
    defer rl.UnloadTexture(booth)

    let stack_scale: f32 = 3.0
    let speed_change: f32 = 0.25
    var stack_spacing: f32 = 2.0
    var rotation_speed: f32 = 30.0
    var rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        stack_spacing += rl.GetMouseWheelMove() * 0.1
        stack_spacing = rm.clamp(stack_spacing, 0.0, 5.0)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT) or rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            rotation_speed -= speed_change
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT) or rl.IsKeyDown(rl.KeyboardKey.KEY_D):
            rotation_speed += speed_change

        rotation += rotation_speed * rl.GetFrameTime()

        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)

        let frame_width = cast[f32](booth.width)
        let frame_height = cast[f32](booth.height) / cast[f32](stack_count)
        let scaled_width = frame_width * stack_scale
        let scaled_height = frame_height * stack_scale

        var index = stack_count - 1
        while index >= 0:
            let source = rl.Rectangle(x = 0.0, y = cast[f32](index) * frame_height, width = frame_width, height = frame_height)
            let dest = rl.Rectangle(
                x = cast[f32](screen_width) / 2.0,
                y = cast[f32](screen_height) / 2.0 + cast[f32](index) * stack_spacing - stack_spacing * cast[f32](stack_count) / 2.0,
                width = scaled_width,
                height = scaled_height,
            )
            let origin = rl.Vector2(x = scaled_width / 2.0, y = scaled_height / 2.0)
            rl.DrawTexturePro(booth, source, dest, origin, rotation, rl.WHITE)
            index -= 1

        rl.DrawText(help_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(c"current spacing: %.01f", stack_spacing), 10, 50, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(c"current speed: %.02f", rotation_speed), 10, 70, 20, rl.DARKGRAY)
        rl.DrawText(credit_text, 10, 420, 20, rl.DARKGRAY)

        rl.EndDrawing()

    return 0
