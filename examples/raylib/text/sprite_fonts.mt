import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_FONTS: int = 8


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - sprite fonts")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var fonts: array[rl.Font, MAX_FONTS] = zero[array[rl.Font, MAX_FONTS]]
    fonts[0] = rl.load_font("sprite_fonts/alagard.png")
    fonts[1] = rl.load_font("sprite_fonts/pixelplay.png")
    fonts[2] = rl.load_font("sprite_fonts/mecha.png")
    fonts[3] = rl.load_font("sprite_fonts/setback.png")
    fonts[4] = rl.load_font("sprite_fonts/romulus.png")
    fonts[5] = rl.load_font("sprite_fonts/pixantiqua.png")
    fonts[6] = rl.load_font("sprite_fonts/alpha_beta.png")
    fonts[7] = rl.load_font("sprite_fonts/jupiter_crash.png")

    let messages = array[str, MAX_FONTS](
        "ALAGARD FONT designed by Hewett Tsoi",
        "PIXELPLAY FONT designed by Aleksander Shevchuk",
        "MECHA FONT designed by Captain Falcon",
        "SETBACK FONT designed by Brian Kent (AEnigma)",
        "ROMULUS FONT designed by Hewett Tsoi",
        "PIXANTIQUA FONT designed by Gerhard Grossmann",
        "ALPHA_BETA FONT designed by Brian Kent (AEnigma)",
        "JUPITER_CRASH FONT designed by Brian Kent (AEnigma)",
    )
    let spacings = array[int, MAX_FONTS](2, 4, 8, 4, 3, 4, 4, 1)
    let colors = array[rl.Color, MAX_FONTS](rl.MAROON, rl.ORANGE, rl.DARKGREEN, rl.DARKBLUE, rl.DARKPURPLE, rl.LIME, rl.GOLD, rl.RED)
    var positions: array[rl.Vector2, MAX_FONTS] = zero[array[rl.Vector2, MAX_FONTS]]

    var index = 0
    while index < MAX_FONTS:
        let font_size = float<-fonts[index].baseSize * 2.0
        let spacing = float<-spacings[index]
        positions[index].x = float<-SCREEN_WIDTH / 2.0 - rl.measure_text_ex(fonts[index], messages[index], font_size, spacing).x / 2.0
        positions[index].y = 60.0 + float<-fonts[index].baseSize + 45.0 * float<-index
        index += 1

    positions[3].y += 8.0
    positions[4].y += 2.0
    positions[7].y -= 8.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("free sprite fonts included with raylib", 220, 20, 20, rl.DARKGRAY)
        rl.draw_line(220, 50, 600, 50, rl.DARKGRAY)

        index = 0
        while index < MAX_FONTS:
            rl.draw_text_ex(fonts[index], messages[index], positions[index], float<-fonts[index].baseSize * 2.0, float<-spacings[index], colors[index])
            index += 1

        rl.end_drawing()

    index = 0
    while index < MAX_FONTS:
        rl.unload_font(fonts[index])
        index += 1

    return 0
