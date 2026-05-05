module examples.idiomatic.raylib.bunnymark

import std.mem.heap as heap
import std.raylib as rl
import std.span as sp

struct Bunny:
    position: rl.Vector2
    speed: rl.Vector2
    color: rl.Color

const max_bunnies: int = 80000
const max_batch_elements: int = 8192
const screen_width: int = 800
const screen_height: int = 450
const bunny_path: str = "../../raylib/resources/raybunny.png"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Bunnymark")
    defer rl.close_window()

    let tex_bunny = rl.load_texture(bunny_path)
    defer rl.unload_texture(tex_bunny)

    let bunnies = heap.must_alloc_zeroed[Bunny](ptr_uint<-max_bunnies)
    defer heap.release(bunnies)

    var bunnies_view = sp.from_ptr[Bunny](bunnies, ptr_uint<-max_bunnies)
    var bunnies_count = 0
    var paused = false

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var spawn_count = 0
            while spawn_count < 100:
                if bunnies_count < max_bunnies:
                    bunnies_view[bunnies_count].position = rl.get_mouse_position()
                    bunnies_view[bunnies_count].speed.x = float<-rl.get_random_value(-250, 250)
                    bunnies_view[bunnies_count].speed.y = float<-rl.get_random_value(-250, 250)
                    bunnies_view[bunnies_count].color = rl.Color(
                        r = ubyte<-rl.get_random_value(50, 240),
                        g = ubyte<-rl.get_random_value(80, 240),
                        b = ubyte<-rl.get_random_value(100, 240),
                        a = 255,
                    )
                    bunnies_count += 1
                spawn_count += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            paused = not paused

        if not paused:
            let frame_time = rl.get_frame_time()
            for index in 0..bunnies_count:
                bunnies_view[index].position.x += bunnies_view[index].speed.x * frame_time
                bunnies_view[index].position.y += bunnies_view[index].speed.y * frame_time

                if bunnies_view[index].position.x + float<-tex_bunny.width / 2.0 > float<-rl.get_screen_width() or bunnies_view[index].position.x + float<-tex_bunny.width / 2.0 < 0.0:
                    bunnies_view[index].speed.x *= -1.0
                if bunnies_view[index].position.y + float<-tex_bunny.height / 2.0 > float<-rl.get_screen_height() or bunnies_view[index].position.y + float<-tex_bunny.height / 2.0 - 40.0 < 0.0:
                    bunnies_view[index].speed.y *= -1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in 0..bunnies_count:
            rl.draw_texture(tex_bunny, int<-bunnies_view[index].position.x, int<-bunnies_view[index].position.y, bunnies_view[index].color)

        rl.draw_rectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.draw_text(rl.text_format_int("bunnies: %i", bunnies_count), 120, 10, 20, rl.GREEN)
        rl.draw_text(rl.text_format_int("batched draw calls: %i", 1 + bunnies_count / max_batch_elements), 320, 10, 20, rl.MAROON)
        rl.draw_fps(10, 10)

    return 0
