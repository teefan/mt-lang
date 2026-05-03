module examples.raylib.textures.textures_gif_player

import std.c.raylib as rl

const max_frame_delay: i32 = 20
const min_frame_delay: i32 = 1
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - gif player"
const scarfy_run_path: cstr = c"../resources/scarfy_run.gif"
const total_frames_format: cstr = c"TOTAL GIF FRAMES:  %02i"
const current_frame_format: cstr = c"CURRENT FRAME: %02i"
const current_offset_format: cstr = c"CURRENT FRAME IMAGE.DATA OFFSET: %02i"
const frame_delay_label: cstr = c"FRAMES DELAY: "
const frame_delay_format: cstr = c"%02i frames"
const speed_help_text: cstr = c"PRESS RIGHT/LEFT KEYS to CHANGE SPEED!"
const credit_text: cstr = c"(c) Scarfy sprite by Eiden Marsal"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var anim_frames = 0
    let im_scarfy_anim = rl.LoadImageAnim(scarfy_run_path, ptr_of(ref_of(anim_frames)))
    defer rl.UnloadImage(im_scarfy_anim)

    let tex_scarfy_anim = rl.LoadTextureFromImage(im_scarfy_anim)
    defer rl.UnloadTexture(tex_scarfy_anim)

    var frame_pixels: ptr[u8]
    unsafe:
        frame_pixels = ptr[u8]<-im_scarfy_anim.data

    var next_frame_data_offset = 0
    var current_anim_frame = 0
    var frame_delay = 8
    var frame_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frame_counter += 1

        if frame_counter >= frame_delay:
            current_anim_frame += 1
            if current_anim_frame >= anim_frames:
                current_anim_frame = 0

            next_frame_data_offset = im_scarfy_anim.width * im_scarfy_anim.height * 4 * current_anim_frame
            unsafe:
                rl.UpdateTexture(tex_scarfy_anim, ptr[void]<-(frame_pixels + next_frame_data_offset))

            frame_counter = 0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            frame_delay += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            frame_delay -= 1

        if frame_delay > max_frame_delay:
            frame_delay = max_frame_delay
        elif frame_delay < min_frame_delay:
            frame_delay = min_frame_delay

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(rl.TextFormat(total_frames_format, anim_frames), 50, 30, 20, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(current_frame_format, current_anim_frame), 50, 60, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(current_offset_format, next_frame_data_offset), 50, 90, 20, rl.GRAY)

        rl.DrawText(frame_delay_label, 100, 305, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(frame_delay_format, frame_delay), 620, 305, 10, rl.DARKGRAY)
        rl.DrawText(speed_help_text, 290, 350, 10, rl.DARKGRAY)

        for index in range(0, max_frame_delay):
            if index < frame_delay:
                rl.DrawRectangle(190 + 21 * index, 300, 20, 20, rl.RED)
            rl.DrawRectangleLines(190 + 21 * index, 300, 20, 20, rl.MAROON)

        rl.DrawTexture(tex_scarfy_anim, rl.GetScreenWidth() / 2 - tex_scarfy_anim.width / 2, 140, rl.WHITE)
        rl.DrawText(credit_text, screen_width - 200, screen_height - 20, 10, rl.GRAY)

    return 0
