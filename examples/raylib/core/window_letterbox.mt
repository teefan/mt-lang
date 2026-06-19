import std.raylib as rl
import std.raymath as math

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GAME_SCREEN_WIDTH: int = 640
const GAME_SCREEN_HEIGHT: int = 480
const BAR_COUNT: int = 10


function random_bar_color() -> rl.Color:
    return rl.Color(
        r = ubyte<-rl.get_random_value(100, 250),
        g = ubyte<-rl.get_random_value(50, 150),
        b = ubyte<-rl.get_random_value(10, 100),
        a = 255ub
    )


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - window letterbox")
    defer rl.close_window()

    rl.set_window_min_size(320, 240)

    let target = rl.load_render_texture(GAME_SCREEN_WIDTH, GAME_SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)
    rl.set_texture_filter(target.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var colors: array[rl.Color, BAR_COUNT] = zero[array[rl.Color, BAR_COUNT]]
    var color_index = 0
    while color_index < BAR_COUNT:
        colors[color_index] = random_bar_color()
        color_index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let width_scale = (float<-rl.get_screen_width()) / (float<-GAME_SCREEN_WIDTH)
        let height_scale = (float<-rl.get_screen_height()) / (float<-GAME_SCREEN_HEIGHT)
        var scale = width_scale
        if height_scale < scale:
            scale = height_scale

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            color_index = 0
            while color_index < BAR_COUNT:
                colors[color_index] = random_bar_color()
                color_index += 1

        let mouse = rl.get_mouse_position()
        var virtual_mouse = rl.Vector2(x = 0.0, y = 0.0)
        virtual_mouse.x = (mouse.x - ((float<-rl.get_screen_width()) - ((float<-GAME_SCREEN_WIDTH) * scale)) * 0.5) / scale
        virtual_mouse.y = (mouse.y - ((float<-rl.get_screen_height()) - ((float<-GAME_SCREEN_HEIGHT) * scale)) * 0.5) / scale
        virtual_mouse = math.vector2_clamp(
            virtual_mouse,
            rl.Vector2(x = 0.0, y = 0.0),
            rl.Vector2(x = float<-GAME_SCREEN_WIDTH, y = float<-GAME_SCREEN_HEIGHT)
        )

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)

        color_index = 0
        while color_index < BAR_COUNT:
            rl.draw_rectangle(
                0,
                (GAME_SCREEN_HEIGHT / BAR_COUNT) * color_index,
                GAME_SCREEN_WIDTH,
                GAME_SCREEN_HEIGHT / BAR_COUNT,
                colors[color_index]
            )
            color_index += 1

        rl.draw_text(
            "If executed inside a window,\nyou can resize the window,\nand see the screen scaling!",
            10,
            25,
            20,
            rl.WHITE
        )
        rl.draw_text(f"Default Mouse: [#{int<-mouse.x} , #{int<-mouse.y}]", 350, 25, 20, rl.GREEN)
        rl.draw_text(f"Virtual Mouse: [#{int<-virtual_mouse.x} , #{int<-virtual_mouse.y}]", 350, 55, 20, rl.YELLOW)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)

        let source = rl.Rectangle(
            x = 0.0,
            y = 0.0,
            width = float<-target.texture.width,
            height = -(float<-target.texture.height)
        )
        let destination = rl.Rectangle(
            x = ((float<-rl.get_screen_width()) - ((float<-GAME_SCREEN_WIDTH) * scale)) * 0.5,
            y = ((float<-rl.get_screen_height()) - ((float<-GAME_SCREEN_HEIGHT) * scale)) * 0.5,
            width = (float<-GAME_SCREEN_WIDTH) * scale,
            height = (float<-GAME_SCREEN_HEIGHT) * scale
        )

        rl.draw_texture_pro(target.texture, source, destination, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.end_drawing()

    return 0
