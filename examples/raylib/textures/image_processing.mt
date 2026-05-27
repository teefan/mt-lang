import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_PROCESSES: int = 9
const PROCESS_NONE: int = 0
const PROCESS_COLOR_GRAYSCALE: int = 1
const PROCESS_COLOR_TINT: int = 2
const PROCESS_COLOR_INVERT: int = 3
const PROCESS_COLOR_CONTRAST: int = 4
const PROCESS_COLOR_BRIGHTNESS: int = 5
const PROCESS_GAUSSIAN_BLUR: int = 6
const PROCESS_FLIP_VERTICAL: int = 7
const PROCESS_FLIP_HORIZONTAL: int = 8


function process_text(process: int) -> str:
    if process == PROCESS_NONE:
        return "NO PROCESSING"
    if process == PROCESS_COLOR_GRAYSCALE:
        return "COLOR GRAYSCALE"
    if process == PROCESS_COLOR_TINT:
        return "COLOR TINT"
    if process == PROCESS_COLOR_INVERT:
        return "COLOR INVERT"
    if process == PROCESS_COLOR_CONTRAST:
        return "COLOR CONTRAST"
    if process == PROCESS_COLOR_BRIGHTNESS:
        return "COLOR BRIGHTNESS"
    if process == PROCESS_GAUSSIAN_BLUR:
        return "GAUSSIAN BLUR"
    if process == PROCESS_FLIP_VERTICAL:
        return "FLIP VERTICAL"
    return "FLIP HORIZONTAL"


function apply_process(process: int, image: ref[rl.Image]) -> void:
    if process == PROCESS_COLOR_GRAYSCALE:
        rl.image_color_grayscale(read(image))
    else if process == PROCESS_COLOR_TINT:
        rl.image_color_tint(read(image), rl.GREEN)
    else if process == PROCESS_COLOR_INVERT:
        rl.image_color_invert(read(image))
    else if process == PROCESS_COLOR_CONTRAST:
        rl.image_color_contrast(read(image), -40.0)
    else if process == PROCESS_COLOR_BRIGHTNESS:
        rl.image_color_brightness(read(image), -80)
    else if process == PROCESS_GAUSSIAN_BLUR:
        rl.image_blur_gaussian(read(image), 10)
    else if process == PROCESS_FLIP_VERTICAL:
        rl.image_flip_vertical(read(image))
    else if process == PROCESS_FLIP_HORIZONTAL:
        rl.image_flip_horizontal(read(image))


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image processing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var image_origin = rl.load_image("parrots.png")
    defer rl.unload_image(image_origin)
    rl.image_format(image_origin, int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8)

    let texture = rl.load_texture_from_image(image_origin)
    defer rl.unload_texture(texture)

    var image_copy = rl.image_copy(image_origin)
    defer rl.unload_image(image_copy)

    var current_process = PROCESS_NONE
    var texture_reload = false
    var mouse_hover_rect = -1
    var toggle_rects: array[rl.Rectangle, NUM_PROCESSES] = zero[array[rl.Rectangle, NUM_PROCESSES]]

    var index = 0
    while index < NUM_PROCESSES:
        toggle_rects[index] = rl.Rectangle(x = 40.0, y = float<-(50 + 32 * index), width = 150.0, height = 30.0)
        index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        index = 0
        mouse_hover_rect = -1
        while index < NUM_PROCESSES:
            if rl.check_collision_point_rec(rl.get_mouse_position(), toggle_rects[index]):
                mouse_hover_rect = index
                if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    current_process = index
                    texture_reload = true
                break
            index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            current_process += 1
            if current_process > NUM_PROCESSES - 1:
                current_process = 0
            texture_reload = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            current_process -= 1
            if current_process < 0:
                current_process = PROCESS_FLIP_VERTICAL
            texture_reload = true

        if texture_reload:
            rl.unload_image(image_copy)
            image_copy = rl.image_copy(image_origin)
            apply_process(current_process, ref_of(image_copy))

            let pixels = rl.load_image_colors(image_copy) else:
                fatal("could not load image colors")
            rl.update_texture(texture, pixels)
            rl.unload_image_colors(pixels)

            texture_reload = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("IMAGE PROCESSING:", 40, 30, 10, rl.DARKGRAY)

        index = 0
        while index < NUM_PROCESSES:
            let selected = index == current_process or index == mouse_hover_rect
            let fill = if selected: rl.SKYBLUE else: rl.LIGHTGRAY
            let stroke = if selected: rl.BLUE else: rl.GRAY
            let label_color = if selected: rl.DARKBLUE else: rl.DARKGRAY
            let label = process_text(index)
            let label_x = int<-(toggle_rects[index].x + toggle_rects[index].width / 2.0 - float<-rl.measure_text(label, 10) / 2.0)

            rl.draw_rectangle_rec(toggle_rects[index], fill)
            rl.draw_rectangle_lines(int<-toggle_rects[index].x, int<-toggle_rects[index].y, int<-toggle_rects[index].width, int<-toggle_rects[index].height, stroke)
            rl.draw_text(label, label_x, int<-toggle_rects[index].y + 11, 10, label_color)
            index += 1

        let texture_x = SCREEN_WIDTH - texture.width - 60
        let texture_y = SCREEN_HEIGHT / 2 - texture.height / 2
        rl.draw_texture(texture, texture_x, texture_y, rl.WHITE)
        rl.draw_rectangle_lines(texture_x, texture_y, texture.width, texture.height, rl.BLACK)
        rl.end_drawing()

    return 0
