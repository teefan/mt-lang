module examples.idiomatic.raylib.background_scrolling

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const background_path: str = "../../raylib/resources/cyberpunk_street_background.png"
const midground_path: str = "../../raylib/resources/cyberpunk_street_midground.png"
const foreground_path: str = "../../raylib/resources/cyberpunk_street_foreground.png"
const background_scale: float = 2.0


def reset_scroll(scroll: float, texture_width: int) -> float:
    if scroll <= -float<-(texture_width * 2):
        return 0.0
    return scroll


def draw_layer(texture: rl.Texture2D, scroll: float, y: float) -> void:
    rl.draw_texture_ex(texture, rl.Vector2(x = scroll, y = y), 0.0, background_scale, rl.WHITE)
    rl.draw_texture_ex(texture, rl.Vector2(x = float<-(texture.width * 2) + scroll, y = y), 0.0, background_scale, rl.WHITE)


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Background Scrolling")
    defer rl.close_window()

    let background = rl.load_texture(background_path)
    let midground = rl.load_texture(midground_path)
    let foreground = rl.load_texture(foreground_path)
    defer:
        rl.unload_texture(foreground)
        rl.unload_texture(midground)
        rl.unload_texture(background)

    var scrolling_back: float = 0.0
    var scrolling_mid: float = 0.0
    var scrolling_fore: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        scrolling_back = reset_scroll(scrolling_back - 0.1, background.width)
        scrolling_mid = reset_scroll(scrolling_mid - 0.5, midground.width)
        scrolling_fore = reset_scroll(scrolling_fore - 1.0, foreground.width)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.get_color(0x052c46ff))
        draw_layer(background, scrolling_back, 20.0)
        draw_layer(midground, scrolling_mid, 20.0)
        draw_layer(foreground, scrolling_fore, 70.0)

        rl.draw_text("BACKGROUND SCROLLING & PARALLAX", 10, 10, 20, rl.RED)
        rl.draw_text("(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)", screen_width - 330, screen_height - 20, 10, rl.RAYWHITE)

    return 0
