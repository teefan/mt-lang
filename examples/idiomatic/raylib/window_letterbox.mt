module examples.idiomatic.raylib.window_letterbox

import std.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const game_screen_width: i32 = 640
const game_screen_height: i32 = 480
const bar_count: i32 = 10


def random_bar_color() -> rl.Color:
    return rl.Color(
        r = rl.get_random_value(100, 250),
        g = rl.get_random_value(50, 150),
        b = rl.get_random_value(10, 100),
        a = 255,
    )


def fresh_colors() -> array[rl.Color, 10]:
    var colors = zero[array[rl.Color, 10]]()
    var color_index = 0
    while color_index < bar_count:
        colors[color_index] = random_bar_color()
        color_index += 1
    return colors


def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Letterbox")
    defer rl.close_window()
    rl.set_window_min_size(320, 240)

    let target = rl.load_render_texture(game_screen_width, game_screen_height)
    defer rl.unload_render_texture(target)
    rl.set_texture_filter(target.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var colors = fresh_colors()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let width_scale: f32 = f32<-rl.get_screen_width() / game_screen_width
        let height_scale: f32 = f32<-rl.get_screen_height() / game_screen_height
        var scale = width_scale
        if height_scale < scale:
            scale = height_scale

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            colors = fresh_colors()

        let scaled_game_width = game_screen_width * scale
        let scaled_game_height = game_screen_height * scale
        let offset_x: f32 = (rl.get_screen_width() - scaled_game_width) * 0.5
        let offset_y: f32 = (rl.get_screen_height() - scaled_game_height) * 0.5

        let mouse = rl.get_mouse_position()
        var virtual_mouse = rm.Vector2.zero()
        virtual_mouse.x = (mouse.x - offset_x) / scale
        virtual_mouse.y = (mouse.y - offset_y) / scale
        virtual_mouse = virtual_mouse.clamp(
            rm.Vector2.zero(),
            rl.Vector2(x = game_screen_width, y = game_screen_height),
        )

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)

        let stripe_height = game_screen_height / bar_count
        var color_index = 0
        while color_index < bar_count:
            rl.draw_rectangle(0, stripe_height * color_index, game_screen_width, stripe_height, colors[color_index])
            color_index += 1

        rl.draw_text("If executed inside a window,\nyou can resize the window,\nand see the screen scaling!", 10, 25, 20, rl.WHITE)
        rl.draw_text(rl.text_format_i32_i32("Default Mouse: [%i , %i]", i32<-mouse.x, i32<-mouse.y), 350, 25, 20, rl.GREEN)
        rl.draw_text(rl.text_format_i32_i32("Virtual Mouse: [%i , %i]", i32<-virtual_mouse.x, i32<-virtual_mouse.y), 350, 55, 20, rl.YELLOW)

        rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        rl.draw_texture_pro(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = target.texture.width,
                height = -target.texture.height,
            ),
            rl.Rectangle(
                x = offset_x,
                y = offset_y,
                width = scaled_game_width,
                height = scaled_game_height,
            ),
            rm.Vector2.zero(),
            0.0,
            rl.WHITE,
        )

    return 0
