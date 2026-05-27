import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_FRAMES: int = 3


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - sprite button")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fx_button = rl.load_sound("buttonfx.wav")
    defer rl.unload_sound(fx_button)
    let button = rl.load_texture("button.png")
    defer rl.unload_texture(button)

    let frame_height = float<-button.height / float<-NUM_FRAMES
    var source_rect = rl.Rectangle(x = float<-0.0, y = float<-0.0, width = float<-button.width, height = frame_height)

    let button_bounds = rl.Rectangle(
        x = float<-SCREEN_WIDTH / float<-2.0 - float<-button.width / float<-2.0,
        y = float<-SCREEN_HEIGHT / float<-2.0 - float<-button.height / float<-NUM_FRAMES / float<-2.0,
        width = float<-button.width,
        height = frame_height,
    )

    var button_state = 0
    var button_action = false
    var mouse_point = rl.Vector2(x = float<-0.0, y = float<-0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_point = rl.get_mouse_position()
        button_action = false

        if rl.check_collision_point_rec(mouse_point, button_bounds):
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                button_state = 2
            else:
                button_state = 1

            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                button_action = true
        else:
            button_state = 0

        if button_action:
            rl.play_sound(fx_button)

        source_rect.y = float<-button_state * frame_height

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_rec(button, source_rect, rl.Vector2(x = button_bounds.x, y = button_bounds.y), rl.WHITE)
        rl.end_drawing()

    return 0
