import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - font spritefont")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let msg1 = "THIS IS A custom SPRITE FONT..."
    let msg2 = "...and this is ANOTHER CUSTOM font..."
    let msg3 = "...and a THIRD one! GREAT! :D"

    let font1 = rl.load_font("custom_mecha.png")
    defer rl.unload_font(font1)
    let font2 = rl.load_font("custom_alagard.png")
    defer rl.unload_font(font2)
    let font3 = rl.load_font("custom_jupiter_crash.png")
    defer rl.unload_font(font3)

    let font_position1 = rl.Vector2(
        x = float<-SCREEN_WIDTH / 2.0 - rl.measure_text_ex(font1, msg1, float<-font1.baseSize, -3.0).x / 2.0,
        y = float<-SCREEN_HEIGHT / 2.0 - float<-font1.baseSize / 2.0 - 80.0,
    )
    let font_position2 = rl.Vector2(
        x = float<-SCREEN_WIDTH / 2.0 - rl.measure_text_ex(font2, msg2, float<-font2.baseSize, -2.0).x / 2.0,
        y = float<-SCREEN_HEIGHT / 2.0 - float<-font2.baseSize / 2.0 - 10.0,
    )
    let font_position3 = rl.Vector2(
        x = float<-SCREEN_WIDTH / 2.0 - rl.measure_text_ex(font3, msg3, float<-font3.baseSize, 2.0).x / 2.0,
        y = float<-SCREEN_HEIGHT / 2.0 - float<-font3.baseSize / 2.0 + 50.0,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text_ex(font1, msg1, font_position1, float<-font1.baseSize, -3.0, rl.WHITE)
        rl.draw_text_ex(font2, msg2, font_position2, float<-font2.baseSize, -2.0, rl.WHITE)
        rl.draw_text_ex(font3, msg3, font_position3, float<-font3.baseSize, 2.0, rl.WHITE)

        rl.end_drawing()

    return 0
