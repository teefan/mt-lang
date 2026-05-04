module examples.idiomatic.raylib.image_kernel

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const cat_path: str = "../../raylib/resources/cat.png"


def normalize_kernel(kernel: array[f32, 9]) -> array[f32, 9]:
    var values = kernel
    var sum: f32 = 0.0
    for index in 0..9:
        sum += values[index]

    if sum != 0.0:
        for index in 0..9:
            values[index] /= sum

    return values


def apply_kernel(image: rl.Image, kernel: array[f32, 9], passes: i32) -> rl.Image:
    var result = image
    var kernel_values = kernel
    for index in 0..passes:
        let _ = index
        rl.image_kernel_convolution(inout result, const_ptr_of(kernel_values[0]), 9)
    return result


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Kernel")
    defer rl.close_window()

    var image = rl.load_image(cat_path)

    let gaussian_kernel = normalize_kernel(array[f32, 9](
        1.0, 2.0, 1.0,
        2.0, 4.0, 2.0,
        1.0, 2.0, 1.0,
    ))
    let sobel_kernel = normalize_kernel(array[f32, 9](
        1.0, 0.0, -1.0,
        2.0, 0.0, -2.0,
        1.0, 0.0, -1.0,
    ))
    let sharpen_kernel = normalize_kernel(array[f32, 9](
        0.0, -1.0, 0.0,
       -1.0, 5.0, -1.0,
        0.0, -1.0, 0.0,
    ))

    var cat_sharpened = apply_kernel(rl.image_copy(image), sharpen_kernel, 1)
    var cat_sobel = apply_kernel(rl.image_copy(image), sobel_kernel, 1)
    var cat_gaussian = apply_kernel(rl.image_copy(image), gaussian_kernel, 6)

    let crop = rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0)
    rl.image_crop(inout image, crop)
    rl.image_crop(inout cat_gaussian, crop)
    rl.image_crop(inout cat_sobel, crop)
    rl.image_crop(inout cat_sharpened, crop)

    let texture = rl.load_texture_from_image(image)
    let cat_sharpened_texture = rl.load_texture_from_image(cat_sharpened)
    let cat_sobel_texture = rl.load_texture_from_image(cat_sobel)
    let cat_gaussian_texture = rl.load_texture_from_image(cat_gaussian)

    rl.unload_image(image)
    rl.unload_image(cat_gaussian)
    rl.unload_image(cat_sobel)
    rl.unload_image(cat_sharpened)

    defer:
        rl.unload_texture(cat_gaussian_texture)
        rl.unload_texture(cat_sobel_texture)
        rl.unload_texture(cat_sharpened_texture)
        rl.unload_texture(texture)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(cat_sharpened_texture, 0, 0, rl.WHITE)
        rl.draw_texture(cat_sobel_texture, 200, 0, rl.WHITE)
        rl.draw_texture(cat_gaussian_texture, 400, 0, rl.WHITE)
        rl.draw_texture(texture, 600, 0, rl.WHITE)

    return 0
