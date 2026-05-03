module examples.raylib.textures.textures_screen_buffer

import std.c.raylib as rl
import std.mem.heap as heap

const max_colors: i32 = 256
const scale_factor: i32 = 2
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - screen buffer"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let image_width = screen_width / scale_factor
    let image_height = screen_height / scale_factor
    let flame_width = screen_width / scale_factor

    var palette = zero[array[rl.Color, 256]]()
    for index in range(0, max_colors):
        let t = f32<-index / f32<-(max_colors - 1)
        let hue = t * t
        let saturation = t
        let value = t
        palette[index] = rl.ColorFromHSV(250.0 + 150.0 * hue, saturation, value)

    unsafe:
        let index_buffer = heap.must_alloc_zeroed[u8](usize<-(image_width * image_height))
        let flame_root_buffer = heap.must_alloc_zeroed[u8](usize<-flame_width)
        var screen_image = rl.GenImageColor(image_width, image_height, rl.BLACK)
        let screen_texture = rl.LoadTextureFromImage(screen_image)

        defer:
            rl.UnloadTexture(screen_texture)
            rl.UnloadImage(screen_image)
            heap.release(flame_root_buffer)
            heap.release(index_buffer)

        rl.SetTargetFPS(60)

        while not rl.WindowShouldClose():
            for x in range(2, flame_width):
                var flame = i32<-read(flame_root_buffer + x)
                flame += rl.GetRandomValue(0, 2)
                read(flame_root_buffer + x) = if flame > 255: u8<-255 else: u8<-flame

            for x in range(0, flame_width):
                let index = x + (image_height - 1) * image_width
                read(index_buffer + index) = read(flame_root_buffer + x)

            for x in range(0, image_width):
                if read(index_buffer + x) != 0:
                    read(index_buffer + x) = 0

            for y in range(1, image_height):
                for x in range(0, image_width):
                    let index = x + y * image_width
                    let color_index = i32<-read(index_buffer + index)

                    if color_index != 0:
                        read(index_buffer + index) = 0
                        let move_x = rl.GetRandomValue(0, 2) - 1
                        let new_x = x + move_x

                        if new_x > 0 and new_x < image_width:
                            let index_above = index - image_width + move_x
                            let decay = rl.GetRandomValue(0, 3)
                            let next_color_index = color_index - (if decay < color_index: decay else: color_index)
                            read(index_buffer + index_above) = u8<-next_color_index

            for y in range(1, image_height):
                for x in range(0, image_width):
                    let index = x + y * image_width
                    let color_index = i32<-read(index_buffer + index)
                    rl.ImageDrawPixel(ptr_of(ref_of(screen_image)), x, y, palette[color_index])

            rl.UpdateTexture(screen_texture, screen_image.data)

            rl.BeginDrawing()
            rl.ClearBackground(rl.RAYWHITE)
            rl.DrawTextureEx(screen_texture, rl.Vector2(x = 0.0, y = 0.0), 0.0, 2.0, rl.WHITE)
            rl.EndDrawing()

    return 0