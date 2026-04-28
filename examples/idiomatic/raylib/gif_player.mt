module examples.idiomatic.raylib.gif_player

import std.raylib as rl

const max_frame_delay: i32 = 20
const min_frame_delay: i32 = 1
const screen_width: i32 = 800
const screen_height: i32 = 450
const scarfy_run_path: str = "../../raylib/textures/resources/scarfy_run.gif"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea GIF Player")
    defer rl.close_window()

    var anim_frames = 0
    let im_scarfy_anim = rl.load_image_anim(scarfy_run_path, out anim_frames)
    defer rl.unload_image(im_scarfy_anim)

    let tex_scarfy_anim = rl.load_texture_from_image(im_scarfy_anim)
    defer rl.unload_texture(tex_scarfy_anim)

    var next_frame_data_offset = 0
    var current_anim_frame = 0
    var frame_delay = 8
    var frame_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frame_counter += 1

        if frame_counter >= frame_delay:
            current_anim_frame += 1
            if current_anim_frame >= anim_frames:
                current_anim_frame = 0

            next_frame_data_offset = im_scarfy_anim.width * im_scarfy_anim.height * 4 * current_anim_frame
            rl.update_texture_from_image_frame(tex_scarfy_anim, im_scarfy_anim, current_anim_frame)

            frame_counter = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            frame_delay += 1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            frame_delay -= 1

        if frame_delay > max_frame_delay:
            frame_delay = max_frame_delay
        elif frame_delay < min_frame_delay:
            frame_delay = min_frame_delay

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(rl.text_format_i32("TOTAL GIF FRAMES:  %02i", anim_frames), 50, 30, 20, rl.LIGHTGRAY)
        rl.draw_text(rl.text_format_i32("CURRENT FRAME: %02i", current_anim_frame), 50, 60, 20, rl.GRAY)
        rl.draw_text(rl.text_format_i32("CURRENT FRAME IMAGE.DATA OFFSET: %02i", next_frame_data_offset), 50, 90, 20, rl.GRAY)

        rl.draw_text("FRAMES DELAY: ", 100, 305, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_i32("%02i frames", frame_delay), 620, 305, 10, rl.DARKGRAY)
        rl.draw_text("PRESS RIGHT/LEFT KEYS to CHANGE SPEED!", 290, 350, 10, rl.DARKGRAY)

        for index in range(0, max_frame_delay):
            if index < frame_delay:
                rl.draw_rectangle(190 + 21 * index, 300, 20, 20, rl.RED)
            rl.draw_rectangle_lines(190 + 21 * index, 300, 20, 20, rl.MAROON)

        rl.draw_texture(tex_scarfy_anim, rl.get_screen_width() / 2 - tex_scarfy_anim.width / 2, 140, rl.WHITE)
        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", screen_width - 200, screen_height - 20, 10, rl.GRAY)

    return 0
