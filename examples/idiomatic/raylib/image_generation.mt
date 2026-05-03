module examples.idiomatic.raylib.image_generation

import std.raylib as rl

const num_textures: i32 = 9
const screen_width: i32 = 800
const screen_height: i32 = 450


def texture_label(texture_index: i32) -> str:
    if texture_index == 0:
        return "VERTICAL GRADIENT"
    elif texture_index == 1:
        return "HORIZONTAL GRADIENT"
    elif texture_index == 2:
        return "DIAGONAL GRADIENT"
    elif texture_index == 3:
        return "RADIAL GRADIENT"
    elif texture_index == 4:
        return "SQUARE GRADIENT"
    elif texture_index == 5:
        return "CHECKED"
    elif texture_index == 6:
        return "WHITE NOISE"
    elif texture_index == 7:
        return "PERLIN NOISE"
    return "CELLULAR"


def texture_label_color(texture_index: i32) -> rl.Color:
    if texture_index <= 2:
        return rl.RAYWHITE
    elif texture_index <= 4:
        return rl.LIGHTGRAY
    elif texture_index == 5:
        return rl.RAYWHITE
    elif texture_index <= 7:
        return rl.RED
    return rl.RAYWHITE


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Generation")
    defer rl.close_window()

    let vertical_gradient = rl.gen_image_gradient_linear(screen_width, screen_height, 0, rl.RED, rl.BLUE)
    let horizontal_gradient = rl.gen_image_gradient_linear(screen_width, screen_height, 90, rl.RED, rl.BLUE)
    let diagonal_gradient = rl.gen_image_gradient_linear(screen_width, screen_height, 45, rl.RED, rl.BLUE)
    let radial_gradient = rl.gen_image_gradient_radial(screen_width, screen_height, 0.0, rl.WHITE, rl.BLACK)
    let square_gradient = rl.gen_image_gradient_square(screen_width, screen_height, 0.0, rl.WHITE, rl.BLACK)
    let checked = rl.gen_image_checked(screen_width, screen_height, 32, 32, rl.RED, rl.BLUE)
    let white_noise = rl.gen_image_white_noise(screen_width, screen_height, 0.5)
    let perlin_noise = rl.gen_image_perlin_noise(screen_width, screen_height, 50, 50, 4.0)
    let cellular = rl.gen_image_cellular(screen_width, screen_height, 32)

    var textures = zero[array[rl.Texture2D, 9]]()
    defer:
        for texture_index in range(0, num_textures):
            rl.unload_texture(textures[texture_index])

    textures[0] = rl.load_texture_from_image(vertical_gradient)
    textures[1] = rl.load_texture_from_image(horizontal_gradient)
    textures[2] = rl.load_texture_from_image(diagonal_gradient)
    textures[3] = rl.load_texture_from_image(radial_gradient)
    textures[4] = rl.load_texture_from_image(square_gradient)
    textures[5] = rl.load_texture_from_image(checked)
    textures[6] = rl.load_texture_from_image(white_noise)
    textures[7] = rl.load_texture_from_image(perlin_noise)
    textures[8] = rl.load_texture_from_image(cellular)

    rl.unload_image(vertical_gradient)
    rl.unload_image(horizontal_gradient)
    rl.unload_image(diagonal_gradient)
    rl.unload_image(radial_gradient)
    rl.unload_image(square_gradient)
    rl.unload_image(checked)
    rl.unload_image(white_noise)
    rl.unload_image(perlin_noise)
    rl.unload_image(cellular)

    var current_texture = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % num_textures

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(textures[current_texture], 0, 0, rl.WHITE)

        rl.draw_rectangle(30, 400, 325, 30, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(30, 400, 325, 30, rl.fade(rl.WHITE, 0.5))
        rl.draw_text("MOUSE LEFT BUTTON to CYCLE PROCEDURAL TEXTURES", 40, 410, 10, rl.WHITE)
        rl.draw_text(texture_label(current_texture), 540, 10, 20, texture_label_color(current_texture))

    return 0
