module examples.raylib.textures.textures_image_kernel

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - image kernel"
const cat_path: cstr = c"../resources/cat.png"


def normalize_kernel(kernel: ptr[f32], size: i32) -> void:
    unsafe:
        var sum: f32 = 0.0
        for index in range(0, size):
            sum += read(kernel + index)

        if sum != 0.0:
            for index in range(0, size):
                read(kernel + index) /= sum


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var image = rl.LoadImage(cat_path)

    var gaussian_kernel = array[f32, 9](
        1.0, 2.0, 1.0,
        2.0, 4.0, 2.0,
        1.0, 2.0, 1.0,
    )
    var sobel_kernel = array[f32, 9](
        1.0, 0.0, -1.0,
        2.0, 0.0, -2.0,
        1.0, 0.0, -1.0,
    )
    var sharpen_kernel = array[f32, 9](
        0.0, -1.0, 0.0,
       -1.0, 5.0, -1.0,
        0.0, -1.0, 0.0,
    )

    normalize_kernel(ptr_of(ref_of(gaussian_kernel[0])), 9)
    normalize_kernel(ptr_of(ref_of(sharpen_kernel[0])), 9)
    normalize_kernel(ptr_of(ref_of(sobel_kernel[0])), 9)

    var cat_sharpened = rl.ImageCopy(image)
    rl.ImageKernelConvolution(ptr_of(ref_of(cat_sharpened)), ptr_of(ref_of(sharpen_kernel[0])), 9)

    var cat_sobel = rl.ImageCopy(image)
    rl.ImageKernelConvolution(ptr_of(ref_of(cat_sobel)), ptr_of(ref_of(sobel_kernel[0])), 9)

    var cat_gaussian = rl.ImageCopy(image)
    for index in range(0, 6):
        let _ = index
        rl.ImageKernelConvolution(ptr_of(ref_of(cat_gaussian)), ptr_of(ref_of(gaussian_kernel[0])), 9)

    let crop = rl.Rectangle(x = 0.0, y = 0.0, width = 200.0, height = 450.0)
    rl.ImageCrop(ptr_of(ref_of(image)), crop)
    rl.ImageCrop(ptr_of(ref_of(cat_gaussian)), crop)
    rl.ImageCrop(ptr_of(ref_of(cat_sobel)), crop)
    rl.ImageCrop(ptr_of(ref_of(cat_sharpened)), crop)

    let texture = rl.LoadTextureFromImage(image)
    let cat_sharpened_texture = rl.LoadTextureFromImage(cat_sharpened)
    let cat_sobel_texture = rl.LoadTextureFromImage(cat_sobel)
    let cat_gaussian_texture = rl.LoadTextureFromImage(cat_gaussian)

    rl.UnloadImage(image)
    rl.UnloadImage(cat_gaussian)
    rl.UnloadImage(cat_sobel)
    rl.UnloadImage(cat_sharpened)

    defer:
        rl.UnloadTexture(cat_gaussian_texture)
        rl.UnloadTexture(cat_sobel_texture)
        rl.UnloadTexture(cat_sharpened_texture)
        rl.UnloadTexture(texture)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(cat_sharpened_texture, 0, 0, rl.WHITE)
        rl.DrawTexture(cat_sobel_texture, 200, 0, rl.WHITE)
        rl.DrawTexture(cat_gaussian_texture, 400, 0, rl.WHITE)
        rl.DrawTexture(texture, 600, 0, rl.WHITE)

    return 0
