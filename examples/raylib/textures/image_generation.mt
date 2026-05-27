import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_TEXTURES: int = 9


function texture_label(current_texture: int) -> str:
    if current_texture == 0:
        return "VERTICAL GRADIENT"
    if current_texture == 1:
        return "HORIZONTAL GRADIENT"
    if current_texture == 2:
        return "DIAGONAL GRADIENT"
    if current_texture == 3:
        return "RADIAL GRADIENT"
    if current_texture == 4:
        return "SQUARE GRADIENT"
    if current_texture == 5:
        return "CHECKED"
    if current_texture == 6:
        return "WHITE NOISE"
    if current_texture == 7:
        return "PERLIN NOISE"
    return "CELLULAR"


function texture_label_color(current_texture: int) -> rl.Color:
    if current_texture == 3 or current_texture == 4:
        return rl.LIGHTGRAY
    if current_texture == 6 or current_texture == 7:
        return rl.RED
    return rl.RAYWHITE


function texture_label_x(current_texture: int) -> int:
    if current_texture == 0:
        return 560
    if current_texture == 1 or current_texture == 2:
        return 540
    if current_texture == 3 or current_texture == 4:
        return 580
    if current_texture == 5:
        return 680
    if current_texture == 6 or current_texture == 7:
        return 640
    return 670


function selected_texture(current_texture: int, textures: array[rl.Texture2D, NUM_TEXTURES]) -> rl.Texture2D:
    return textures[current_texture]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image generation")
    defer rl.close_window()

    let vertical_gradient = rl.gen_image_gradient_linear(SCREEN_WIDTH, SCREEN_HEIGHT, 0, rl.RED, rl.BLUE)
    defer rl.unload_image(vertical_gradient)
    let horizontal_gradient = rl.gen_image_gradient_linear(SCREEN_WIDTH, SCREEN_HEIGHT, 90, rl.RED, rl.BLUE)
    defer rl.unload_image(horizontal_gradient)
    let diagonal_gradient = rl.gen_image_gradient_linear(SCREEN_WIDTH, SCREEN_HEIGHT, 45, rl.RED, rl.BLUE)
    defer rl.unload_image(diagonal_gradient)
    let radial_gradient = rl.gen_image_gradient_radial(SCREEN_WIDTH, SCREEN_HEIGHT, 0.0, rl.WHITE, rl.BLACK)
    defer rl.unload_image(radial_gradient)
    let square_gradient = rl.gen_image_gradient_square(SCREEN_WIDTH, SCREEN_HEIGHT, 0.0, rl.WHITE, rl.BLACK)
    defer rl.unload_image(square_gradient)
    let checked = rl.gen_image_checked(SCREEN_WIDTH, SCREEN_HEIGHT, 32, 32, rl.RED, rl.BLUE)
    defer rl.unload_image(checked)
    let white_noise = rl.gen_image_white_noise(SCREEN_WIDTH, SCREEN_HEIGHT, 0.5)
    defer rl.unload_image(white_noise)
    let perlin_noise = rl.gen_image_perlin_noise(SCREEN_WIDTH, SCREEN_HEIGHT, 50, 50, 4.0)
    defer rl.unload_image(perlin_noise)
    let cellular = rl.gen_image_cellular(SCREEN_WIDTH, SCREEN_HEIGHT, 32)
    defer rl.unload_image(cellular)

    var textures: array[rl.Texture2D, NUM_TEXTURES] = zero[array[rl.Texture2D, NUM_TEXTURES]]
    textures[0] = rl.load_texture_from_image(vertical_gradient)
    textures[1] = rl.load_texture_from_image(horizontal_gradient)
    textures[2] = rl.load_texture_from_image(diagonal_gradient)
    textures[3] = rl.load_texture_from_image(radial_gradient)
    textures[4] = rl.load_texture_from_image(square_gradient)
    textures[5] = rl.load_texture_from_image(checked)
    textures[6] = rl.load_texture_from_image(white_noise)
    textures[7] = rl.load_texture_from_image(perlin_noise)
    textures[8] = rl.load_texture_from_image(cellular)
    defer:
        var index = 0
        while index < NUM_TEXTURES:
            rl.unload_texture(textures[index])
            index += 1

    var current_texture = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % NUM_TEXTURES

        let texture = selected_texture(current_texture, textures)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(texture, 0, 0, rl.WHITE)
        rl.draw_rectangle(30, 400, 325, 30, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(30, 400, 325, 30, rl.fade(rl.WHITE, 0.5))
        rl.draw_text("MOUSE LEFT BUTTON to CYCLE PROCEDURAL TEXTURES", 40, 410, 10, rl.WHITE)
        rl.draw_text(texture_label(current_texture), texture_label_x(current_texture), 10, 20, texture_label_color(current_texture))

        rl.end_drawing()

    return 0
