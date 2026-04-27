module examples.raylib.textures.textures_sprite_explosion

import std.c.raylib as rl

const num_frames_per_line: i32 = 5
const num_lines: i32 = 5
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - sprite explosion"
const boom_path: cstr = c"resources/boom.wav"
const explosion_path: cstr = c"resources/explosion.png"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let fx_boom = rl.LoadSound(boom_path)
    let explosion = rl.LoadTexture(explosion_path)

    defer:
        rl.UnloadTexture(explosion)
        rl.UnloadSound(fx_boom)

    let frame_width = cast[f32](explosion.width) / cast[f32](num_frames_per_line)
    let frame_height = cast[f32](explosion.height) / cast[f32](num_lines)

    var current_frame = 0
    var current_line = 0
    var frame_rec = rl.Rectangle(x = 0.0, y = 0.0, width = frame_width, height = frame_height)
    var position = rl.Vector2(x = 0.0, y = 0.0)
    var active = false
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and not active:
            position = rl.GetMousePosition()
            active = true

            position.x -= frame_width / 2.0
            position.y -= frame_height / 2.0

            rl.PlaySound(fx_boom)

        if active:
            frames_counter += 1

            if frames_counter > 2:
                current_frame += 1

                if current_frame >= num_frames_per_line:
                    current_frame = 0
                    current_line += 1

                    if current_line >= num_lines:
                        current_line = 0
                        active = false

                frames_counter = 0

        frame_rec.x = frame_width * cast[f32](current_frame)
        frame_rec.y = frame_height * cast[f32](current_line)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if active:
            rl.DrawTextureRec(explosion, frame_rec, position, rl.WHITE)

    return 0
