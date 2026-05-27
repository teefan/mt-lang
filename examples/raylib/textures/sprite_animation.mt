import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_FRAME_SPEED: int = 15
const MIN_FRAME_SPEED: int = 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - sprite animation")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let scarfy = rl.load_texture("scarfy.png")
    defer rl.unload_texture(scarfy)

    let position = rl.Vector2(x = float<-350.0, y = float<-280.0)
    var frame_rect = rl.Rectangle(x = float<-0.0, y = float<-0.0, width = float<-scarfy.width / float<-6.0, height = float<-scarfy.height)
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

            frame_rect.x = float<-current_frame * frame_rect.width

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            frames_speed += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            frames_speed -= 1

        if frames_speed > MAX_FRAME_SPEED:
            frames_speed = MAX_FRAME_SPEED
        else if frames_speed < MIN_FRAME_SPEED:
            frames_speed = MIN_FRAME_SPEED

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(scarfy, 15, 40, rl.WHITE)
        rl.draw_rectangle_lines(15, 40, scarfy.width, scarfy.height, rl.LIME)
        rl.draw_rectangle_lines(15 + int<-frame_rect.x, 40 + int<-frame_rect.y, int<-frame_rect.width, int<-frame_rect.height, rl.RED)

        let frame_speed_text = rl.text_format("%02i FPS", frames_speed)
        rl.draw_text("FRAME SPEED: ", 165, 210, 10, rl.DARKGRAY)
        rl.draw_text(frame_speed_text, 575, 210, 10, rl.DARKGRAY)
        rl.draw_text("PRESS RIGHT/LEFT KEYS to CHANGE SPEED!", 290, 240, 10, rl.DARKGRAY)

        var i = 0
        while i < MAX_FRAME_SPEED:
            if i < frames_speed:
                rl.draw_rectangle(250 + 21 * i, 205, 20, 20, rl.RED)
            rl.draw_rectangle_lines(250 + 21 * i, 205, 20, 20, rl.MAROON)
            i += 1

        rl.draw_texture_rec(scarfy, frame_rect, position, rl.WHITE)
        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
