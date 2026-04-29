module examples.raylib.textures.textures_image_processing

import std.c.raylib as rl

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
const window_title: cstr = c"raylib [textures] example - image processing"
const parrots_path: cstr = c"../resources/parrots.png"
const title_text: cstr = c"IMAGE PROCESSING:"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var image_origin = rl.LoadImage(parrots_path)
    rl.ImageFormat(raw(addr(image_origin)), rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8)

    let texture = rl.LoadTextureFromImage(image_origin)
    var image_copy = rl.ImageCopy(image_origin)

    defer:
        rl.UnloadImage(image_copy)
        rl.UnloadImage(image_origin)
        rl.UnloadTexture(texture)

    var process_text = zero[array[cstr, num_processes]]()
    process_text[0] = c"NO PROCESSING"
    process_text[1] = c"COLOR GRAYSCALE"
    process_text[2] = c"COLOR TINT"
    process_text[3] = c"COLOR INVERT"
    process_text[4] = c"COLOR CONTRAST"
    process_text[5] = c"COLOR BRIGHTNESS"
    process_text[6] = c"GAUSSIAN BLUR"
    process_text[7] = c"FLIP VERTICAL"
    process_text[8] = c"FLIP HORIZONTAL"

    var toggle_rects = zero[array[rl.Rectangle, num_processes]]()
    for index in range(0, num_processes):
        toggle_rects[index] = rl.Rectangle(x = 40.0, y = cast[f32](50 + 32 * index), width = 150.0, height = 30.0)

    var current_process = process_none
    var texture_reload = false
    var mouse_hover_rect = -1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        mouse_hover_rect = -1
        for index in range(0, num_processes):
            if rl.CheckCollisionPointRec(rl.GetMousePosition(), toggle_rects[index]):
                mouse_hover_rect = index

                if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    current_process = index
                    texture_reload = true
                break

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            current_process += 1
            if current_process > num_processes - 1:
                current_process = 0
            texture_reload = true
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            current_process -= 1
            if current_process < 0:
                current_process = num_processes - 1
            texture_reload = true

        if texture_reload:
            rl.UnloadImage(image_copy)
            image_copy = rl.ImageCopy(image_origin)

            if current_process == process_color_grayscale:
                rl.ImageColorGrayscale(raw(addr(image_copy)))
            elif current_process == process_color_tint:
                rl.ImageColorTint(raw(addr(image_copy)), rl.GREEN)
            elif current_process == process_color_invert:
                rl.ImageColorInvert(raw(addr(image_copy)))
            elif current_process == process_color_contrast:
                rl.ImageColorContrast(raw(addr(image_copy)), -40.0)
            elif current_process == process_color_brightness:
                rl.ImageColorBrightness(raw(addr(image_copy)), -80)
            elif current_process == process_gaussian_blur:
                rl.ImageBlurGaussian(raw(addr(image_copy)), 10)
            elif current_process == process_flip_vertical:
                rl.ImageFlipVertical(raw(addr(image_copy)))
            elif current_process == process_flip_horizontal:
                rl.ImageFlipHorizontal(raw(addr(image_copy)))

            let pixels = rl.LoadImageColors(image_copy)
            rl.UpdateTexture(texture, pixels)
            rl.UnloadImageColors(pixels)

            texture_reload = false

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(title_text, 40, 30, 10, rl.DARKGRAY)

        for index in range(0, num_processes):
            let active = index == current_process or index == mouse_hover_rect
            let fill_color = if active then rl.SKYBLUE else rl.LIGHTGRAY
            let stroke_color = if active then rl.BLUE else rl.GRAY
            let text_color = if active then rl.DARKBLUE else rl.DARKGRAY

            rl.DrawRectangleRec(toggle_rects[index], fill_color)
            rl.DrawRectangleLines(
                cast[i32](toggle_rects[index].x),
                cast[i32](toggle_rects[index].y),
                cast[i32](toggle_rects[index].width),
                cast[i32](toggle_rects[index].height),
                stroke_color,
            )
            rl.DrawText(
                process_text[index],
                cast[i32](toggle_rects[index].x + toggle_rects[index].width / 2.0 - cast[f32](rl.MeasureText(process_text[index], 10)) / 2.0),
                cast[i32](toggle_rects[index].y) + 11,
                10,
                text_color,
            )

        rl.DrawTexture(texture, screen_width - texture.width - 60, screen_height / 2 - texture.height / 2, rl.WHITE)
        rl.DrawRectangleLines(screen_width - texture.width - 60, screen_height / 2 - texture.height / 2, texture.width, texture.height, rl.BLACK)

        rl.EndDrawing()

    return 0
