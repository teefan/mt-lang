import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function normalize_kernel(kernel: ref[array[float, 9]]) -> void:
    var sum = float<-0.0
    var index = 0
    while index < 9:
        sum += read(kernel)[index]
        index += 1

    if sum != 0.0:
        index = 0
        while index < 9:
            read(kernel)[index] /= sum
            index += 1


function kernel_span(kernel: ref[array[float, 9]]) -> span[float]:
    return unsafe: span[float](data = ptr[float]<-ptr_of(read(kernel)[0]), len = 9)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image kernel")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var image = rl.load_image("cat.png")
    defer rl.unload_image(image)

    var gaussian_kernel = array[float, 9](1.0, 2.0, 1.0, 2.0, 4.0, 2.0, 1.0, 2.0, 1.0)
    var sobel_kernel = array[float, 9](1.0, 0.0, -1.0, 2.0, 0.0, -2.0, 1.0, 0.0, -1.0)
    var sharpen_kernel = array[float, 9](0.0, -1.0, 0.0, -1.0, 5.0, -1.0, 0.0, -1.0, 0.0)

    normalize_kernel(ref_of(gaussian_kernel))
    normalize_kernel(ref_of(sharpen_kernel))
    normalize_kernel(ref_of(sobel_kernel))

    var cat_sharpened = rl.image_copy(image)
    defer rl.unload_image(cat_sharpened)
    rl.image_kernel_convolution(cat_sharpened, kernel_span(ref_of(sharpen_kernel)))

    var cat_sobel = rl.image_copy(image)
    defer rl.unload_image(cat_sobel)
    rl.image_kernel_convolution(cat_sobel, kernel_span(ref_of(sobel_kernel)))

    var cat_gaussian = rl.image_copy(image)
    defer rl.unload_image(cat_gaussian)

    var index = 0
    while index < 6:
        rl.image_kernel_convolution(cat_gaussian, kernel_span(ref_of(gaussian_kernel)))
        index += 1

    rl.image_crop(image, rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0))
    rl.image_crop(cat_gaussian, rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0))
    rl.image_crop(cat_sobel, rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0))
    rl.image_crop(cat_sharpened, rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0))

    let texture = rl.load_texture_from_image(image)
    defer rl.unload_texture(texture)
    let cat_sharpened_texture = rl.load_texture_from_image(cat_sharpened)
    defer rl.unload_texture(cat_sharpened_texture)
    let cat_sobel_texture = rl.load_texture_from_image(cat_sobel)
    defer rl.unload_texture(cat_sobel_texture)
    let cat_gaussian_texture = rl.load_texture_from_image(cat_gaussian)
    defer rl.unload_texture(cat_gaussian_texture)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(cat_sharpened_texture, 0, 0, rl.WHITE)
        rl.draw_texture(cat_sobel_texture, 200, 0, rl.WHITE)
        rl.draw_texture(cat_gaussian_texture, 400, 0, rl.WHITE)
        rl.draw_texture(texture, 600, 0, rl.WHITE)

        rl.end_drawing()

    return 0
