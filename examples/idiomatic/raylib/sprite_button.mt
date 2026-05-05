module examples.idiomatic.raylib.sprite_button

import std.raylib as rl

const num_frames: int = 3
const screen_width: int = 800
const screen_height: int = 450
const button_fx_path: str = "../../raylib/resources/buttonfx.wav"
const button_path: str = "../../raylib/resources/button.png"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Button")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    let fx_button = rl.load_sound(button_fx_path)
    let button = rl.load_texture(button_path)

    defer:
        rl.unload_texture(button)
        rl.unload_sound(fx_button)

    let frame_height = float<-button.height / float<-num_frames
    var source_rec = rl.Rectangle(x = 0.0, y = 0.0, width = float<-button.width, height = frame_height)
    let btn_bounds = rl.Rectangle(
        x = float<-screen_width / 2.0 - float<-button.width / 2.0,
        y = float<-screen_height / 2.0 - float<-button.height / float<-num_frames / 2.0,
        width = float<-button.width,
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

        source_rec.y = float<-btn_state * frame_height

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_rec(button, source_rec, rl.Vector2(x = btn_bounds.x, y = btn_bounds.y), rl.WHITE)

    return 0
