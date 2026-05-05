module examples.idiomatic.raylib.sprite_fonts

import std.raylib as rl

const max_fonts: int = 8
const screen_width: int = 800
const screen_height: int = 450


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Fonts")
    defer rl.close_window()

    let font_paths = array[str, max_fonts](
        "../../raylib/resources/sprite_fonts/alagard.png",
        "../../raylib/resources/sprite_fonts/pixelplay.png",
        "../../raylib/resources/sprite_fonts/mecha.png",
        "../../raylib/resources/sprite_fonts/setback.png",
        "../../raylib/resources/sprite_fonts/romulus.png",
        "../../raylib/resources/sprite_fonts/pixantiqua.png",
        "../../raylib/resources/sprite_fonts/alpha_beta.png",
        "../../raylib/resources/sprite_fonts/jupiter_crash.png",
    )
    let messages = array[str, max_fonts](
        "ALAGARD FONT designed by Hewett Tsoi",
        "PIXELPLAY FONT designed by Aleksander Shevchuk",
        "MECHA FONT designed by Captain Falcon",
        "SETBACK FONT designed by Brian Kent (AEnigma)",
        "ROMULUS FONT designed by Hewett Tsoi",
        "PIXANTIQUA FONT designed by Gerhard Grossmann",
        "ALPHA_BETA FONT designed by Brian Kent (AEnigma)",
        "JUPITER_CRASH FONT designed by Brian Kent (AEnigma)",
    )
    let spacings = array[int, max_fonts](2, 4, 8, 4, 3, 4, 4, 1)
    let colors = array[rl.Color, max_fonts](rl.MAROON, rl.ORANGE, rl.DARKGREEN, rl.DARKBLUE, rl.DARKPURPLE, rl.LIME, rl.GOLD, rl.RED)

    var fonts = zero[array[rl.Font, max_fonts]]
    var positions = zero[array[rl.Vector2, max_fonts]]

    for index in 0..max_fonts:
        fonts[index] = rl.load_font(font_paths[index])
        let size = rl.measure_text_ex(fonts[index], messages[index], float<-fonts[index].baseSize * 2.0, float<-spacings[index])
        positions[index].x = float<-screen_width / 2.0 - size.x / 2.0
        positions[index].y = 60.0 + float<-fonts[index].baseSize + 45.0 * float<-index

    positions[3].y += 8.0
    positions[4].y += 2.0
    positions[7].y -= 8.0

    defer:
        for index in 0..max_fonts:
            rl.unload_font(fonts[index])

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("free sprite fonts included with raylib", 220, 20, 20, rl.DARKGRAY)
        rl.draw_line(220, 50, 600, 50, rl.DARKGRAY)

        for index in 0..max_fonts:
            rl.draw_text_ex(fonts[index], messages[index], positions[index], float<-fonts[index].baseSize * 2.0, float<-spacings[index], colors[index])

    return 0
