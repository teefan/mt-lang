module examples.idiomatic.raylib.sprite_stacking

import std.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const stack_count: i32 = 122
const booth_path: str = "../../raylib/resources/booth.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Stacking")
    defer rl.close_window()

    let booth = rl.load_texture(booth_path)
    defer rl.unload_texture(booth)

    let stack_scale: f32 = 3.0
    let speed_change: f32 = 0.25
    var stack_spacing: f32 = 2.0
    var rotation_speed: f32 = 30.0
    var rotation: f32 = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        stack_spacing += rl.get_mouse_wheel_move() * 0.1
        stack_spacing = rm.clamp(stack_spacing, 0.0, 5.0)

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) or rl.is_key_down(rl.KeyboardKey.KEY_A):
            rotation_speed -= speed_change
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT) or rl.is_key_down(rl.KeyboardKey.KEY_D):
            rotation_speed += speed_change

        rotation += rotation_speed * rl.get_frame_time()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        let frame_width = f32<-booth.width
        let frame_height = f32<-booth.height / f32<-stack_count
        let scaled_width = frame_width * stack_scale
        let scaled_height = frame_height * stack_scale

        var index = stack_count - 1
        while index >= 0:
            let source = rl.Rectangle(x = 0.0, y = f32<-index * frame_height, width = frame_width, height = frame_height)
            let dest = rl.Rectangle(
                x = f32<-screen_width / 2.0,
                y = f32<-screen_height / 2.0 + f32<-index * stack_spacing - stack_spacing * f32<-stack_count / 2.0,
                width = scaled_width,
                height = scaled_height,
            )
            let origin = rl.Vector2(x = scaled_width / 2.0, y = scaled_height / 2.0)
            rl.draw_texture_pro(booth, source, dest, origin, rotation, rl.WHITE)
            index -= 1

        rl.draw_text("A/D to spin", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("mouse wheel to change separation", 10, 30, 20, rl.DARKGRAY)
        rl.draw_text(rl.text_format_f32("current spacing: %.01f", stack_spacing), 10, 60, 20, rl.DARKGRAY)
        rl.draw_text(rl.text_format_f32("current speed: %.02f", rotation_speed), 10, 80, 20, rl.DARKGRAY)
        rl.draw_text("redbooth model (c) kluchek under cc 4.0", 10, 420, 20, rl.DARKGRAY)

    return 0
