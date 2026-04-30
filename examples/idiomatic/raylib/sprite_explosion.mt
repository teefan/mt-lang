module examples.idiomatic.raylib.sprite_explosion

import std.raylib as rl

const num_frames_per_line: i32 = 5
const num_lines: i32 = 5
const screen_width: i32 = 800
const screen_height: i32 = 450
const boom_path: str = "../../raylib/resources/boom.wav"
const explosion_path: str = "../../raylib/resources/explosion.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Explosion")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    let fx_boom = rl.load_sound(boom_path)
    let explosion = rl.load_texture(explosion_path)

    defer:
        rl.unload_texture(explosion)
        rl.unload_sound(fx_boom)

    let frame_width = f32<-explosion.width / f32<-num_frames_per_line
    let frame_height = f32<-explosion.height / f32<-num_lines

    var current_frame = 0
    var current_line = 0
    var frame_rec = rl.Rectangle(x = 0.0, y = 0.0, width = frame_width, height = frame_height)
    var position = rl.Vector2(x = 0.0, y = 0.0)
    var active = false
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and not active:
            position = rl.get_mouse_position()
            active = true

            position.x -= frame_width / 2.0
            position.y -= frame_height / 2.0

            rl.play_sound(fx_boom)

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

        frame_rec.x = frame_width * f32<-current_frame
        frame_rec.y = frame_height * f32<-current_line

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if active:
            rl.draw_texture_rec(explosion, frame_rec, position, rl.WHITE)

    return 0
