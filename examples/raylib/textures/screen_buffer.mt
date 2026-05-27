import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_COLORS: int = 256
const SCALE_FACTOR: int = 2
const IMAGE_WIDTH: int = SCREEN_WIDTH / SCALE_FACTOR
const IMAGE_HEIGHT: int = SCREEN_HEIGHT / SCALE_FACTOR
const FLAME_WIDTH: int = SCREEN_WIDTH / SCALE_FACTOR
const IMAGE_PIXEL_COUNT: int = IMAGE_WIDTH * IMAGE_HEIGHT


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - screen buffer")
    defer rl.close_window()

    var palette: array[rl.Color, MAX_COLORS] = zero[array[rl.Color, MAX_COLORS]]
    var index_buffer: array[ubyte, IMAGE_PIXEL_COUNT] = zero[array[ubyte, IMAGE_PIXEL_COUNT]]
    var flame_root_buffer: array[ubyte, FLAME_WIDTH] = zero[array[ubyte, FLAME_WIDTH]]

    var screen_image = rl.gen_image_color(IMAGE_WIDTH, IMAGE_HEIGHT, rl.BLACK)
    defer rl.unload_image(screen_image)
    let screen_texture = rl.load_texture_from_image(screen_image)
    defer rl.unload_texture(screen_texture)

    var index = 0
    while index < MAX_COLORS:
        let t = float<-index / float<-(MAX_COLORS - 1)
        let hue = t * t
        palette[index] = rl.color_from_hsv(250.0 + 150.0 * hue, t, t)
        index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var x = 2
        while x < FLAME_WIDTH:
            var flame = int<-flame_root_buffer[x]
            flame += rl.get_random_value(0, 2)
            flame_root_buffer[x] = if flame > 255: 255 else: ubyte<-flame
            x += 1

        x = 0
        while x < FLAME_WIDTH:
            let bottom_index = x + ((IMAGE_HEIGHT - 1) * IMAGE_WIDTH)
            index_buffer[bottom_index] = flame_root_buffer[x]
            x += 1

        x = 0
        while x < IMAGE_WIDTH:
            if index_buffer[x] != 0:
                index_buffer[x] = 0
            x += 1

        var y = 1
        while y < IMAGE_HEIGHT:
            x = 0
            while x < IMAGE_WIDTH:
                let pixel_index = x + (y * IMAGE_WIDTH)
                var color_index = index_buffer[pixel_index]

                if color_index != 0:
                    index_buffer[pixel_index] = 0
                    let move_x = rl.get_random_value(0, 2) - 1
                    let new_x = x + move_x

                    if new_x > 0 and new_x < IMAGE_WIDTH:
                        let above_index = pixel_index - IMAGE_WIDTH + move_x
                        let decay = rl.get_random_value(0, 3)
                        if decay < int<-color_index:
                            color_index -= ubyte<-decay
                        else:
                            color_index = 0
                        index_buffer[above_index] = color_index

                x += 1
            y += 1

        y = 1
        while y < IMAGE_HEIGHT:
            x = 0
            while x < IMAGE_WIDTH:
                let pixel_index = x + (y * IMAGE_WIDTH)
                rl.image_draw_pixel(screen_image, x, y, palette[index_buffer[pixel_index]])
                x += 1
            y += 1

        rl.update_texture(screen_texture, unsafe: ptr[rl.Color]<-screen_image.data)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_ex(screen_texture, rl.Vector2(x = 0.0, y = 0.0), 0.0, float<-SCALE_FACTOR, rl.WHITE)
        rl.end_drawing()

    return 0
