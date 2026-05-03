module examples.idiomatic.raylib.sprite_animation

import std.raylib as rl

const max_frame_speed: i32 = 15
const min_frame_speed: i32 = 1
const screen_width: i32 = 800
const screen_height: i32 = 450
const scarfy_path: str = "../../raylib/resources/scarfy.png"


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Animation")
    defer rl.close_window()

    let scarfy = rl.load_texture(scarfy_path)
    defer rl.unload_texture(scarfy)

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

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frames_counter += 1

        if frames_counter >= 60 / frames_speed:
            frames_counter = 0
            current_frame += 1

            if current_frame > 5:
                current_frame = 0

            frame_rec.x = f32<-(current_frame * frame_width)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            frames_speed += 1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            frames_speed -= 1

        if frames_speed > max_frame_speed:
            frames_speed = max_frame_speed
        elif frames_speed < min_frame_speed:
            frames_speed = min_frame_speed

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(scarfy, 15, 40, rl.WHITE)
        rl.draw_rectangle_lines(15, 40, scarfy.width, scarfy.height, rl.LIME)
        rl.draw_rectangle_lines(15 + i32<-frame_rec.x, 40 + i32<-frame_rec.y, i32<-frame_rec.width, i32<-frame_rec.height, rl.RED)

        rl.draw_text("FRAME SPEED: ", 165, 210, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_i32("%02i FPS", frames_speed), 575, 210, 10, rl.DARKGRAY)
        rl.draw_text("PRESS RIGHT/LEFT KEYS to CHANGE SPEED!", 290, 240, 10, rl.DARKGRAY)

        for index in range(0, max_frame_speed):
            if index < frames_speed:
                rl.draw_rectangle(250 + 21 * index, 205, 20, 20, rl.RED)
            rl.draw_rectangle_lines(250 + 21 * index, 205, 20, 20, rl.MAROON)

        rl.draw_texture_rec(scarfy, frame_rec, position, rl.WHITE)
        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", screen_width - 200, screen_height - 20, 10, rl.GRAY)

    return 0
