module examples.idiomatic.raylib.bunnymark

import std.mem.heap as heap
import std.raylib as rl

struct Bunny:
    position: rl.Vector2
    speed: rl.Vector2
    color: rl.Color

const max_bunnies: i32 = 80000
const max_batch_elements: i32 = 8192
const screen_width: i32 = 800
const screen_height: i32 = 450
const bunny_path: str = "../../raylib/textures/resources/raybunny.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Bunnymark")
    defer rl.close_window()

    let tex_bunny = rl.load_texture(bunny_path)
    defer rl.unload_texture(tex_bunny)

    let bunnies = heap.must_alloc_zeroed[Bunny](cast[usize](max_bunnies))
    defer heap.release(bunnies)

    var bunnies_view = span[Bunny](data = bunnies, len = cast[usize](max_bunnies))
    var bunnies_count = 0
    var paused = false

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var spawn_count = 0
            while spawn_count < 100:
                if bunnies_count < max_bunnies:
                    bunnies_view[bunnies_count].position = rl.get_mouse_position()
                    bunnies_view[bunnies_count].speed.x = cast[f32](rl.get_random_value(-250, 250))
                    bunnies_view[bunnies_count].speed.y = cast[f32](rl.get_random_value(-250, 250))
                    bunnies_view[bunnies_count].color = rl.Color(
                        r = cast[u8](rl.get_random_value(50, 240)),
                        g = cast[u8](rl.get_random_value(80, 240)),
                        b = cast[u8](rl.get_random_value(100, 240)),
                        a = 255,
                    )
                    bunnies_count += 1
                spawn_count += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            paused = not paused

        if not paused:
            let frame_time = rl.get_frame_time()
            for index in range(0, bunnies_count):
                bunnies_view[index].position.x += bunnies_view[index].speed.x * frame_time
                bunnies_view[index].position.y += bunnies_view[index].speed.y * frame_time

                if bunnies_view[index].position.x + cast[f32](tex_bunny.width) / 2.0 > cast[f32](rl.get_screen_width()) or bunnies_view[index].position.x + cast[f32](tex_bunny.width) / 2.0 < 0.0:
                    bunnies_view[index].speed.x *= -1.0
                if bunnies_view[index].position.y + cast[f32](tex_bunny.height) / 2.0 > cast[f32](rl.get_screen_height()) or bunnies_view[index].position.y + cast[f32](tex_bunny.height) / 2.0 - 40.0 < 0.0:
                    bunnies_view[index].speed.y *= -1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in range(0, bunnies_count):
            rl.draw_texture(tex_bunny, cast[i32](bunnies_view[index].position.x), cast[i32](bunnies_view[index].position.y), bunnies_view[index].color)

        rl.draw_rectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.draw_text(rl.text_format_i32("bunnies: %i", bunnies_count), 120, 10, 20, rl.GREEN)
        rl.draw_text(rl.text_format_i32("batched draw calls: %i", 1 + bunnies_count / max_batch_elements), 320, 10, 20, rl.MAROON)
        rl.draw_fps(10, 10)

    return 0
