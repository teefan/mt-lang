module examples.idiomatic.raylib.screen_buffer

import std.mem.heap as heap
import std.raylib as rl

const max_colors: i32 = 256
const scale_factor: i32 = 2
const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Screen Buffer")
    defer rl.close_window()

    let image_width = screen_width / scale_factor
    let image_height = screen_height / scale_factor
    let flame_width = screen_width / scale_factor

    var palette = zero[array[rl.Color, 256]]()
    for index in range(0, max_colors):
        let t = cast[f32](index) / cast[f32](max_colors - 1)
        let hue = t * t
        let saturation = t
        let value = t
        palette[index] = rl.color_from_hsv(250.0 + 150.0 * hue, saturation, value)

    let index_buffer_ptr = heap.must_alloc_zeroed[u8](cast[usize](image_width * image_height))
    let flame_root_ptr = heap.must_alloc_zeroed[u8](cast[usize](flame_width))
    defer:
        heap.release(flame_root_ptr)
        heap.release(index_buffer_ptr)

    var index_buffer = span[u8](data = index_buffer_ptr, len = cast[usize](image_width * image_height))
    var flame_root_buffer = span[u8](data = flame_root_ptr, len = cast[usize](flame_width))
    var screen_image = rl.gen_image_color(image_width, image_height, rl.BLACK)
    let screen_texture = rl.load_texture_from_image(screen_image)

    defer:
        rl.unload_texture(screen_texture)
        rl.unload_image(screen_image)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        for x in range(2, flame_width):
            var flame = cast[i32](flame_root_buffer[x])
            flame += rl.get_random_value(0, 2)
            flame_root_buffer[x] = if flame > 255 then cast[u8](255) else cast[u8](flame)

        for x in range(0, flame_width):
            let index = x + (image_height - 1) * image_width
            index_buffer[index] = flame_root_buffer[x]

        for x in range(0, image_width):
            if index_buffer[x] != 0:
                index_buffer[x] = 0

        for y in range(1, image_height):
            for x in range(0, image_width):
                let index = x + y * image_width
                let color_index = cast[i32](index_buffer[index])

                if color_index != 0:
                    index_buffer[index] = 0
                    let move_x = rl.get_random_value(0, 2) - 1
                    let new_x = x + move_x

                    if new_x > 0 and new_x < image_width:
                        let index_above = index - image_width + move_x
                        let decay = rl.get_random_value(0, 3)
                        let next_color_index = color_index - (if decay < color_index then decay else color_index)
                        index_buffer[index_above] = cast[u8](next_color_index)

        for y in range(1, image_height):
            for x in range(0, image_width):
                let index = x + y * image_width
                let color_index = cast[i32](index_buffer[index])
                rl.image_draw_pixel(inout screen_image, x, y, palette[color_index])

        rl.update_texture_from_image(screen_texture, screen_image)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_ex(screen_texture, rl.Vector2(x = 0.0, y = 0.0), 0.0, 2.0, rl.WHITE)

    return 0
