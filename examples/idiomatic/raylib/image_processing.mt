module examples.idiomatic.raylib.image_processing

import std.raylib as rl

const num_processes: i32 = 9
const process_none: i32 = 0
const process_color_grayscale: i32 = 1
const process_color_tint: i32 = 2
const process_color_invert: i32 = 3
const process_color_contrast: i32 = 4
const process_color_brightness: i32 = 5
const process_gaussian_blur: i32 = 6
const process_flip_vertical: i32 = 7
const process_flip_horizontal: i32 = 8
const screen_width: i32 = 800
const screen_height: i32 = 450
const parrots_path: str = "../../raylib/resources/parrots.png"


def process_label(process: i32) -> str:
    if process == process_none:
        return "NO PROCESSING"
    elif process == process_color_grayscale:
        return "COLOR GRAYSCALE"
    elif process == process_color_tint:
        return "COLOR TINT"
    elif process == process_color_invert:
        return "COLOR INVERT"
    elif process == process_color_contrast:
        return "COLOR CONTRAST"
    elif process == process_color_brightness:
        return "COLOR BRIGHTNESS"
    elif process == process_gaussian_blur:
        return "GAUSSIAN BLUR"
    elif process == process_flip_vertical:
        return "FLIP VERTICAL"
    return "FLIP HORIZONTAL"


def apply_process(image: rl.Image, process: i32) -> rl.Image:
    var processed = image
    if process == process_color_grayscale:
        rl.image_color_grayscale(inout processed)
    elif process == process_color_tint:
        rl.image_color_tint(inout processed, rl.GREEN)
    elif process == process_color_invert:
        rl.image_color_invert(inout processed)
    elif process == process_color_contrast:
        rl.image_color_contrast(inout processed, -40.0)
    elif process == process_color_brightness:
        rl.image_color_brightness(inout processed, -80)
    elif process == process_gaussian_blur:
        rl.image_blur_gaussian(inout processed, 10)
    elif process == process_flip_vertical:
        rl.image_flip_vertical(inout processed)
    elif process == process_flip_horizontal:
        rl.image_flip_horizontal(inout processed)
    return processed


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Processing")
    defer rl.close_window()

    var image_origin = rl.load_image(parrots_path)
    rl.image_format(inout image_origin, rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8)

    let texture = rl.load_texture_from_image(image_origin)
    var image_copy = rl.image_copy(image_origin)

    defer:
        rl.unload_texture(texture)
        rl.unload_image(image_copy)
        rl.unload_image(image_origin)

    var toggle_rects = zero[array[rl.Rectangle, 9]]()
    for index in 0..num_processes:
        toggle_rects[index] = rl.Rectangle(x = 40.0, y = f32<-(50 + 32 * index), width = 150.0, height = 30.0)

    var current_process = process_none
    var texture_reload = false
    var mouse_hover_rect = -1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_hover_rect = -1
        for index in 0..num_processes:
            if rl.check_collision_point_rec(rl.get_mouse_position(), toggle_rects[index]):
                mouse_hover_rect = index

                if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    current_process = index
                    texture_reload = true
                break

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            current_process += 1
            if current_process > num_processes - 1:
                current_process = 0
            texture_reload = true
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            current_process -= 1
            if current_process < 0:
                current_process = num_processes - 1
            texture_reload = true

        if texture_reload:
            rl.unload_image(image_copy)
            image_copy = rl.image_copy(image_origin)
            image_copy = apply_process(image_copy, current_process)

            let pixels = rl.load_image_colors(image_copy)
            rl.update_texture(texture, pixels)
            rl.unload_image_colors(pixels)

            texture_reload = false

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("IMAGE PROCESSING:", 40, 30, 10, rl.DARKGRAY)

        for index in 0..num_processes:
            let active = index == current_process or index == mouse_hover_rect
            let fill_color = if active: rl.SKYBLUE else: rl.LIGHTGRAY
            let stroke_color = if active: rl.BLUE else: rl.GRAY
            let text_color = if active: rl.DARKBLUE else: rl.DARKGRAY
            let label = process_label(index)

            rl.draw_rectangle_rec(toggle_rects[index], fill_color)
            rl.draw_rectangle_lines(
                i32<-toggle_rects[index].x,
                i32<-toggle_rects[index].y,
                i32<-toggle_rects[index].width,
                i32<-toggle_rects[index].height,
                stroke_color,
            )
            rl.draw_text(
                label,
                i32<-(toggle_rects[index].x + toggle_rects[index].width / 2.0 - f32<-rl.measure_text(label, 10) / 2.0),
                i32<-toggle_rects[index].y + 11,
                10,
                text_color,
            )

        rl.draw_texture(texture, screen_width - texture.width - 60, screen_height / 2 - texture.height / 2, rl.WHITE)
        rl.draw_rectangle_lines(screen_width - texture.width - 60, screen_height / 2 - texture.height / 2, texture.width, texture.height, rl.BLACK)

    return 0
