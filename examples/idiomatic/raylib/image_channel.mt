module examples.idiomatic.raylib.image_channel

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const fudesumi_path: str = "../../raylib/resources/fudesumi.png"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Channel")
    defer rl.close_window()

    let fudesumi_image = rl.load_image(fudesumi_path)

    var image_alpha = rl.image_from_channel(fudesumi_image, 3)
    rl.image_alpha_mask(inout image_alpha, image_alpha)

    var image_red = rl.image_from_channel(fudesumi_image, 0)
    rl.image_alpha_mask(inout image_red, image_alpha)

    var image_green = rl.image_from_channel(fudesumi_image, 1)
    rl.image_alpha_mask(inout image_green, image_alpha)

    var image_blue = rl.image_from_channel(fudesumi_image, 2)
    rl.image_alpha_mask(inout image_blue, image_alpha)

    let background_image = rl.gen_image_checked(screen_width, screen_height, screen_width / 20, screen_height / 20, rl.ORANGE, rl.YELLOW)

    let fudesumi_texture = rl.load_texture_from_image(fudesumi_image)
    let texture_alpha = rl.load_texture_from_image(image_alpha)
    let texture_red = rl.load_texture_from_image(image_red)
    let texture_green = rl.load_texture_from_image(image_green)
    let texture_blue = rl.load_texture_from_image(image_blue)
    let background_texture = rl.load_texture_from_image(background_image)

    rl.unload_image(fudesumi_image)
    rl.unload_image(image_alpha)
    rl.unload_image(image_red)
    rl.unload_image(image_green)
    rl.unload_image(image_blue)
    rl.unload_image(background_image)

    defer:
        rl.unload_texture(background_texture)
        rl.unload_texture(fudesumi_texture)
        rl.unload_texture(texture_red)
        rl.unload_texture(texture_green)
        rl.unload_texture(texture_blue)
        rl.unload_texture(texture_alpha)

    let fudesumi_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-fudesumi_texture.width,
        height = float<-fudesumi_texture.height,
    )
    let fudesumi_pos = rl.Rectangle(
        x = 50.0,
        y = 10.0,
        width = float<-fudesumi_texture.width * 0.8,
        height = float<-fudesumi_texture.height * 0.8,
    )
    let red_pos = rl.Rectangle(x = 410.0, y = 10.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let green_pos = rl.Rectangle(x = 600.0, y = 10.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let blue_pos = rl.Rectangle(x = 410.0, y = 230.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let alpha_pos = rl.Rectangle(x = 600.0, y = 230.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.draw_texture(background_texture, 0, 0, rl.WHITE)
        rl.draw_texture_pro(fudesumi_texture, fudesumi_rec, fudesumi_pos, origin, 0.0, rl.WHITE)
        rl.draw_texture_pro(texture_red, fudesumi_rec, red_pos, origin, 0.0, rl.RED)
        rl.draw_texture_pro(texture_green, fudesumi_rec, green_pos, origin, 0.0, rl.GREEN)
        rl.draw_texture_pro(texture_blue, fudesumi_rec, blue_pos, origin, 0.0, rl.BLUE)
        rl.draw_texture_pro(texture_alpha, fudesumi_rec, alpha_pos, origin, 0.0, rl.WHITE)

    return 0
