module examples.idiomatic.raylib.font_spritefont

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const msg1: str = "THIS IS A custom SPRITE FONT..."
const msg2: str = "...and this is ANOTHER CUSTOM font..."
const msg3: str = "...and a THIRD one! GREAT! :D"
const font1_path: str = "../../raylib/resources/custom_mecha.png"
const font2_path: str = "../../raylib/resources/custom_alagard.png"
const font3_path: str = "../../raylib/resources/custom_jupiter_crash.png"


def centered_position(font: rl.Font, text: str, spacing: f32, y_offset: f32) -> rl.Vector2:
    let size = rl.measure_text_ex(font, text, f32<-font.baseSize, spacing)
    return rl.Vector2(
        x = f32<-screen_width / 2.0 - size.x / 2.0,
        y = f32<-screen_height / 2.0 - f32<-font.baseSize / 2.0 + y_offset,
    )


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Sprite Font")
    defer rl.close_window()

    let font1 = rl.load_font(font1_path)
    defer rl.unload_font(font1)

    let font2 = rl.load_font(font2_path)
    defer rl.unload_font(font2)

    let font3 = rl.load_font(font3_path)
    defer rl.unload_font(font3)

    let font_position1 = centered_position(font1, msg1, -3.0, -80.0)
    let font_position2 = centered_position(font2, msg2, -2.0, -10.0)
    let font_position3 = centered_position(font3, msg3, 2.0, 50.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text_ex(font1, msg1, font_position1, f32<-font1.baseSize, -3.0, rl.WHITE)
        rl.draw_text_ex(font2, msg2, font_position2, f32<-font2.baseSize, -2.0, rl.WHITE)
        rl.draw_text_ex(font3, msg3, font_position3, f32<-font3.baseSize, 2.0, rl.WHITE)

    return 0
