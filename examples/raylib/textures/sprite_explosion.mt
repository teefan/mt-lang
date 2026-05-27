import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_FRAMES_PER_LINE: int = 5
const NUM_LINES: int = 5


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - sprite explosion")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fx_boom = rl.load_sound("boom.wav")
    defer rl.unload_sound(fx_boom)
    let explosion = rl.load_texture("explosion.png")
    defer rl.unload_texture(explosion)

    let frame_width = float<-explosion.width / float<-NUM_FRAMES_PER_LINE
    let frame_height = float<-explosion.height / float<-NUM_LINES
    var current_frame = 0
    var current_line = 0

    var frame_rect = rl.Rectangle(x = 0.0, y = 0.0, width = frame_width, height = frame_height)
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

                if current_frame >= NUM_FRAMES_PER_LINE:
                    current_frame = 0
                    current_line += 1

                    if current_line >= NUM_LINES:
                        current_line = 0
                        active = false

                frames_counter = 0

        frame_rect.x = frame_width * float<-current_frame
        frame_rect.y = frame_height * float<-current_line

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if active:
            rl.draw_texture_rec(explosion, frame_rect, position, rl.WHITE)

        rl.end_drawing()

    return 0
