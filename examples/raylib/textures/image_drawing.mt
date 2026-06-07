import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image drawing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var cat = rl.load_image("cat.png")
    rl.image_crop(cat, rl.Rectangle(x = 100.0, y = 10.0, width = 280.0, height = 380.0))
    rl.image_flip_horizontal(cat)
    rl.image_resize(cat, 150, 200)

    var parrots = rl.load_image("parrots.png")
    defer rl.unload_image(parrots)

    rl.image_draw(
        parrots,
        cat,
        rl.Rectangle(x = 0.0, y = 0.0, width = float<-cat.width, height = float<-cat.height),
        rl.Rectangle(x = 30.0, y = 40.0, width = float<-cat.width * 1.5, height = float<-cat.height * 1.5),
        rl.WHITE
    )
    rl.image_crop(
        parrots,
        rl.Rectangle(x = 0.0, y = 50.0, width = float<-parrots.width, height = float<-parrots.height - 100.0)
    )
    rl.image_draw_pixel(parrots, 10, 10, rl.RAYWHITE)
    rl.image_draw_circle_lines(parrots, 10, 10, 5, rl.RAYWHITE)
    rl.image_draw_rectangle(parrots, 5, 20, 10, 10, rl.RAYWHITE)

    rl.unload_image(cat)

    let font = rl.load_font("custom_jupiter_crash.png")
    defer rl.unload_font(font)
    rl.image_draw_text_ex(
        parrots,
        font,
        "PARROTS & CAT",
        rl.Vector2(x = 300.0, y = 230.0),
        float<-font.baseSize,
        float<--2.0,
        rl.WHITE
    )

    let texture = rl.load_texture_from_image(parrots)
    defer rl.unload_texture(texture)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let texture_x = SCREEN_WIDTH / 2 - texture.width / 2
        let texture_y = SCREEN_HEIGHT / 2 - texture.height / 2 - 40

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(texture, texture_x, texture_y, rl.WHITE)
        rl.draw_rectangle_lines(texture_x, texture_y, texture.width, texture.height, rl.DARKGRAY)
        rl.draw_text("We are drawing only one texture from various images composed!", 240, 350, 10, rl.DARKGRAY)
        rl.draw_text(
            "Source images have been cropped, scaled, flipped and copied one over the other.",
            190,
            370,
            10,
            rl.DARKGRAY
        )

        rl.end_drawing()

    return 0
