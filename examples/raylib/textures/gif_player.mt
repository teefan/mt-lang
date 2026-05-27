import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_FRAME_DELAY: int = 20
const MIN_FRAME_DELAY: int = 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - gif player")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var anim_frames = 0
    let scarfy_anim_image = rl.load_image_anim("scarfy_run.gif", anim_frames)
    defer rl.unload_image(scarfy_anim_image)

    let scarfy_anim_texture = rl.load_texture_from_image(scarfy_anim_image)
    defer rl.unload_texture(scarfy_anim_texture)

    let frame_data = unsafe: ptr[ubyte]<-scarfy_anim_image.data

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

            next_frame_data_offset = scarfy_anim_image.width * scarfy_anim_image.height * 4 * current_anim_frame
            rl.update_texture(scarfy_anim_texture, unsafe: frame_data + ptr_uint<-next_frame_data_offset)
            frame_counter = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            frame_delay += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            frame_delay -= 1

        if frame_delay > MAX_FRAME_DELAY:
            frame_delay = MAX_FRAME_DELAY
        else if frame_delay < MIN_FRAME_DELAY:
            frame_delay = MIN_FRAME_DELAY

        let total_frames_text = rl.text_format("TOTAL GIF FRAMES:  %02i", anim_frames)
        let current_frame_text = rl.text_format("CURRENT FRAME: %02i", current_anim_frame)
        let frame_offset_text = rl.text_format("CURRENT FRAME IMAGE.DATA OFFSET: %02i", next_frame_data_offset)
        let frame_delay_text = rl.text_format("%02i frames", frame_delay)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(total_frames_text, 50, 30, 20, rl.LIGHTGRAY)
        rl.draw_text(current_frame_text, 50, 60, 20, rl.GRAY)
        rl.draw_text(frame_offset_text, 50, 90, 20, rl.GRAY)

        rl.draw_text("FRAMES DELAY: ", 100, 305, 10, rl.DARKGRAY)
        rl.draw_text(frame_delay_text, 620, 305, 10, rl.DARKGRAY)
        rl.draw_text("PRESS RIGHT/LEFT KEYS to CHANGE SPEED!", 290, 350, 10, rl.DARKGRAY)

        var index = 0
        while index < MAX_FRAME_DELAY:
            if index < frame_delay:
                rl.draw_rectangle(190 + 21 * index, 300, 20, 20, rl.RED)
            rl.draw_rectangle_lines(190 + 21 * index, 300, 20, 20, rl.MAROON)
            index += 1

        rl.draw_texture(scarfy_anim_texture, rl.get_screen_width() / 2 - scarfy_anim_texture.width / 2, 140, rl.WHITE)
        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)

        rl.end_drawing()

    return 0
