import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image text")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var parrots = rl.load_image("parrots.png")
    let font = rl.load_font_ex("KAISG.ttf", 64, null, 0)
    defer rl.unload_font(font)

    rl.image_draw_text_ex(parrots, font, "[Parrots font drawing]", rl.Vector2(x = 20.0, y = 20.0), float<-font.baseSize, 0.0, rl.RED)

    let texture = rl.load_texture_from_image(parrots)
    defer rl.unload_texture(texture)
    rl.unload_image(parrots)

    let position = rl.Vector2(
        x = float<-SCREEN_WIDTH / 2.0 - float<-texture.width / 2.0,
        y = float<-SCREEN_HEIGHT / 2.0 - float<-texture.height / 2.0 - 20.0,
    )

    var show_font = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        show_font = rl.is_key_down(rl.KeyboardKey.KEY_SPACE)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if not show_font:
            rl.draw_texture_v(texture, position, rl.WHITE)
            rl.draw_text_ex(
                font,
                "[Parrots font drawing]",
                rl.Vector2(x = position.x + 20.0, y = position.y + 300.0),
                float<-font.baseSize,
                0.0,
                rl.WHITE,
            )
        else:
            rl.draw_texture(font.texture, SCREEN_WIDTH / 2 - font.texture.width / 2, 50, rl.BLACK)

        rl.draw_text("PRESS SPACE to SHOW FONT ATLAS USED", 290, 420, 10, rl.DARKGRAY)
        rl.end_drawing()

    return 0
