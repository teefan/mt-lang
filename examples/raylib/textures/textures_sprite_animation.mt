module examples.raylib.textures.textures_sprite_animation

import std.c.raylib as rl

const max_frame_speed: i32 = 15
const min_frame_speed: i32 = 1
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - sprite animation"
const scarfy_path: cstr = c"../resources/scarfy.png"
const frame_speed_label: cstr = c"FRAME SPEED: "
const help_text: cstr = c"PRESS RIGHT/LEFT KEYS to CHANGE SPEED!"
const credit_text: cstr = c"(c) Scarfy sprite by Eiden Marsal"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let scarfy = rl.LoadTexture(scarfy_path)
    defer rl.UnloadTexture(scarfy)

    let frame_width = scarfy.width / 6
    let frame_height = scarfy.height
    let position = rl.Vector2(x = 350.0, y = 280.0)

    var frame_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = f32<-frame_width,
        height = f32<-frame_height,
    )
    var current_frame = 0
    var frames_counter = 0
    var frames_speed = 8

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frames_counter += 1

        if frames_counter >= 60 / frames_speed:
            frames_counter = 0
            current_frame += 1

            if current_frame > 5:
                current_frame = 0

            frame_rec.x = f32<-(current_frame * frame_width)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            frames_speed += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            frames_speed -= 1

        if frames_speed > max_frame_speed:
            frames_speed = max_frame_speed
        elif frames_speed < min_frame_speed:
            frames_speed = min_frame_speed

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawTexture(scarfy, 15, 40, rl.WHITE)
        rl.DrawRectangleLines(15, 40, scarfy.width, scarfy.height, rl.LIME)
        rl.DrawRectangleLines(15 + i32<-frame_rec.x, 40 + i32<-frame_rec.y, i32<-frame_rec.width, i32<-frame_rec.height, rl.RED)

        rl.DrawText(frame_speed_label, 165, 210, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(c"%02i FPS", frames_speed), 575, 210, 10, rl.DARKGRAY)
        rl.DrawText(help_text, 290, 240, 10, rl.DARKGRAY)

        for index in range(0, max_frame_speed):
            if index < frames_speed:
                rl.DrawRectangle(250 + 21 * index, 205, 20, 20, rl.RED)
            rl.DrawRectangleLines(250 + 21 * index, 205, 20, 20, rl.MAROON)

        rl.DrawTextureRec(scarfy, frame_rec, position, rl.WHITE)
        rl.DrawText(credit_text, screen_width - 200, screen_height - 20, 10, rl.GRAY)

        rl.EndDrawing()

    return 0