module examples.idiomatic.raylib.sprite_button

import std.raylib as rl

const num_frames: i32 = 3
const screen_width: i32 = 800
const screen_height: i32 = 450
const button_fx_path: str = "../../raylib/resources/buttonfx.wav"
const button_path: str = "../../raylib/resources/button.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Button")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    let fx_button = rl.load_sound(button_fx_path)
    let button = rl.load_texture(button_path)

    defer:
        rl.unload_texture(button)
        rl.unload_sound(fx_button)

    let frame_height = f32<-button.height / f32<-num_frames
    var source_rec = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-button.width, height = frame_height)
    let btn_bounds = rl.Rectangle(
        x = f32<-screen_width / 2.0 - f32<-button.width / 2.0,
        y = f32<-screen_height / 2.0 - f32<-button.height / f32<-num_frames / 2.0,
        width = f32<-button.width,
        height = frame_height,
    )

    var btn_state = 0
    var btn_action = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_point = rl.get_mouse_position()
        btn_action = false

        if rl.check_collision_point_rec(mouse_point, btn_bounds):
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                btn_state = 2
            else:
                btn_state = 1

            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                btn_action = true
        else:
            btn_state = 0

        if btn_action:
            rl.play_sound(fx_button)

        source_rec.y = f32<-btn_state * frame_height

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_rec(button, source_rec, rl.Vector2(x = btn_bounds.x, y = btn_bounds.y), rl.WHITE)

    return 0