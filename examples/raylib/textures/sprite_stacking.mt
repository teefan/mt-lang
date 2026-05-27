import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const STACK_COUNT: int = 122


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - sprite stacking")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let booth = rl.load_texture("booth.png")
    defer rl.unload_texture(booth)

    var stack_scale = float<-3.0
    var stack_spacing = float<-2.0
    var rotation_speed = float<-30.0
    var rotation = float<-0.0
    let speed_change = float<-0.25

    rl.set_target_fps(60)

    while not rl.window_should_close():
        stack_spacing += rl.get_mouse_wheel_move() * float<-0.1
        stack_spacing = rm.clamp(stack_spacing, 0.0, 5.0)

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) or rl.is_key_down(rl.KeyboardKey.KEY_A):
            rotation_speed -= speed_change
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT) or rl.is_key_down(rl.KeyboardKey.KEY_D):
            rotation_speed += speed_change

        rotation += rotation_speed * rl.get_frame_time()

        let frame_width = float<-booth.width
        let frame_height = float<-booth.height / float<-STACK_COUNT
        let scaled_width = frame_width * stack_scale
        let scaled_height = frame_height * stack_scale

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = STACK_COUNT - 1
        while index >= 0:
            let source = rl.Rectangle(x = 0.0, y = float<-index * frame_height, width = frame_width, height = frame_height)
            let destination = rl.Rectangle(
                x = float<-SCREEN_WIDTH / 2.0,
                y = float<-SCREEN_HEIGHT / 2.0 + float<-index * stack_spacing - stack_spacing * float<-STACK_COUNT / 2.0,
                width = scaled_width,
                height = scaled_height,
            )
            let origin = rl.Vector2(x = scaled_width / 2.0, y = scaled_height / 2.0)

            rl.draw_texture_pro(booth, source, destination, origin, rotation, rl.WHITE)
            index -= 1

        let spacing_text = text.cstr_as_str(rl.text_format("current spacing: %.01f", stack_spacing))
        let speed_text = text.cstr_as_str(rl.text_format("current speed: %.02f", rotation_speed))

        rl.draw_text("A/D to spin\nmouse wheel to change separation (aka 'angle')", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text(spacing_text, 10, 50, 20, rl.DARKGRAY)
        rl.draw_text(speed_text, 10, 70, 20, rl.DARKGRAY)
        rl.draw_text("redbooth model (c) kluchek under cc 4.0", 10, 420, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
