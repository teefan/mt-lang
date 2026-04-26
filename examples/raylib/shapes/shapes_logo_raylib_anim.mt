module examples.raylib.shapes.shapes_logo_raylib_anim

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - logo raylib anim"
const raylib_text: cstr = c"raylib"
const replay_text: cstr = c"[R] REPLAY"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let logo_position_x = screen_width / 2 - 128
    let logo_position_y = screen_height / 2 - 128

    var frames_counter = 0
    var letters_count = 0

    var top_side_rec_width = 16
    var left_side_rec_height = 16

    var bottom_side_rec_width = 16
    var right_side_rec_height = 16

    var state = 0
    var alpha: f32 = 1.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if state == 0:
            frames_counter += 1

            if frames_counter == 120:
                state = 1
                frames_counter = 0
        elif state == 1:
            top_side_rec_width += 4
            left_side_rec_height += 4

            if top_side_rec_width == 256:
                state = 2
        elif state == 2:
            bottom_side_rec_width += 4
            right_side_rec_height += 4

            if bottom_side_rec_width == 256:
                state = 3
        elif state == 3:
            frames_counter += 1

            if frames_counter / 12 != 0:
                letters_count += 1
                frames_counter = 0

            if letters_count >= 10:
                alpha -= 0.02

                if alpha <= 0.0:
                    alpha = 0.0
                    state = 4
        elif state == 4:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
                frames_counter = 0
                letters_count = 0
                top_side_rec_width = 16
                left_side_rec_height = 16
                bottom_side_rec_width = 16
                right_side_rec_height = 16
                alpha = 1.0
                state = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if state == 0:
            if (frames_counter / 15) % 2 != 0:
                rl.DrawRectangle(logo_position_x, logo_position_y, 16, 16, rl.BLACK)
        elif state == 1:
            rl.DrawRectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.BLACK)
            rl.DrawRectangle(logo_position_x, logo_position_y, 16, left_side_rec_height, rl.BLACK)
        elif state == 2:
            rl.DrawRectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.BLACK)
            rl.DrawRectangle(logo_position_x, logo_position_y, 16, left_side_rec_height, rl.BLACK)
            rl.DrawRectangle(logo_position_x + 240, logo_position_y, 16, right_side_rec_height, rl.BLACK)
            rl.DrawRectangle(logo_position_x, logo_position_y + 240, bottom_side_rec_width, 16, rl.BLACK)
        elif state == 3:
            rl.DrawRectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.Fade(rl.BLACK, alpha))
            rl.DrawRectangle(logo_position_x, logo_position_y + 16, 16, left_side_rec_height - 32, rl.Fade(rl.BLACK, alpha))
            rl.DrawRectangle(logo_position_x + 240, logo_position_y + 16, 16, right_side_rec_height - 32, rl.Fade(rl.BLACK, alpha))
            rl.DrawRectangle(logo_position_x, logo_position_y + 240, bottom_side_rec_width, 16, rl.Fade(rl.BLACK, alpha))
            rl.DrawRectangle(rl.GetScreenWidth() / 2 - 112, rl.GetScreenHeight() / 2 - 112, 224, 224, rl.Fade(rl.RAYWHITE, alpha))
            rl.DrawText(rl.TextSubtext(raylib_text, 0, letters_count), rl.GetScreenWidth() / 2 - 44, rl.GetScreenHeight() / 2 + 48, 50, rl.Fade(rl.BLACK, alpha))
        elif state == 4:
            rl.DrawText(replay_text, 340, 200, 20, rl.GRAY)

    return 0
