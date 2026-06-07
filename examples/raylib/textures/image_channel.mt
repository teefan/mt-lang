import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image channel")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fudesumi_image = rl.load_image("fudesumi.png")
    defer rl.unload_image(fudesumi_image)

    var image_alpha = rl.image_from_channel(fudesumi_image, 3)
    defer rl.unload_image(image_alpha)
    rl.image_alpha_mask(image_alpha, image_alpha)

    var image_red = rl.image_from_channel(fudesumi_image, 0)
    defer rl.unload_image(image_red)
    rl.image_alpha_mask(image_red, image_alpha)

    var image_green = rl.image_from_channel(fudesumi_image, 1)
    defer rl.unload_image(image_green)
    rl.image_alpha_mask(image_green, image_alpha)

    var image_blue = rl.image_from_channel(fudesumi_image, 2)
    defer rl.unload_image(image_blue)
    rl.image_alpha_mask(image_blue, image_alpha)

    let background_image = rl.gen_image_checked(
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        SCREEN_WIDTH / 20,
        SCREEN_HEIGHT / 20,
        rl.ORANGE,
        rl.YELLOW
    )
    defer rl.unload_image(background_image)

    let fudesumi_texture = rl.load_texture_from_image(fudesumi_image)
    defer rl.unload_texture(fudesumi_texture)
    let texture_alpha = rl.load_texture_from_image(image_alpha)
    defer rl.unload_texture(texture_alpha)
    let texture_red = rl.load_texture_from_image(image_red)
    defer rl.unload_texture(texture_red)
    let texture_green = rl.load_texture_from_image(image_green)
    defer rl.unload_texture(texture_green)
    let texture_blue = rl.load_texture_from_image(image_blue)
    defer rl.unload_texture(texture_blue)
    let background_texture = rl.load_texture_from_image(background_image)
    defer rl.unload_texture(background_texture)

    let fudesumi_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-fudesumi_image.width,
        height = float<-fudesumi_image.height
    )
    let fudesumi_pos = rl.Rectangle(
        x = 50.0,
        y = 10.0,
        width = float<-fudesumi_image.width * 0.8,
        height = float<-fudesumi_image.height * 0.8
    )
    let red_pos = rl.Rectangle(
        x = 410.0,
        y = 10.0,
        width = fudesumi_pos.width / 2.0,
        height = fudesumi_pos.height / 2.0
    )
    let green_pos = rl.Rectangle(
        x = 600.0,
        y = 10.0,
        width = fudesumi_pos.width / 2.0,
        height = fudesumi_pos.height / 2.0
    )
    let blue_pos = rl.Rectangle(
        x = 410.0,
        y = 230.0,
        width = fudesumi_pos.width / 2.0,
        height = fudesumi_pos.height / 2.0
    )
    let alpha_pos = rl.Rectangle(
        x = 600.0,
        y = 230.0,
        width = fudesumi_pos.width / 2.0,
        height = fudesumi_pos.height / 2.0
    )
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()

        rl.draw_texture(background_texture, 0, 0, rl.WHITE)
        rl.draw_texture_pro(fudesumi_texture, fudesumi_rect, fudesumi_pos, origin, 0.0, rl.WHITE)

        rl.draw_texture_pro(texture_red, fudesumi_rect, red_pos, origin, 0.0, rl.RED)
        rl.draw_texture_pro(texture_green, fudesumi_rect, green_pos, origin, 0.0, rl.GREEN)
        rl.draw_texture_pro(texture_blue, fudesumi_rect, blue_pos, origin, 0.0, rl.BLUE)
        rl.draw_texture_pro(texture_alpha, fudesumi_rect, alpha_pos, origin, 0.0, rl.WHITE)

        rl.end_drawing()

    return 0
