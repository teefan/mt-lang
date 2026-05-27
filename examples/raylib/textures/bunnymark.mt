import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_BUNNIES: int = 80000
const MAX_BATCH_ELEMENTS: int = 8192


struct Bunny:
    position: rl.Vector2
    speed: rl.Vector2
    color: rl.Color


function random_bunny_color() -> rl.Color:
    return rl.Color(
        r = ubyte<-rl.get_random_value(50, 240),
        g = ubyte<-rl.get_random_value(80, 240),
        b = ubyte<-rl.get_random_value(100, 240),
        a = 255,
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - bunnymark")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let bunny_texture = rl.load_texture("raybunny.png")
    defer rl.unload_texture(bunny_texture)

    var bunnies: array[Bunny, MAX_BUNNIES] = zero[array[Bunny, MAX_BUNNIES]]
    var bunny_count = 0
    var paused = false

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var spawn_index = 0
            while spawn_index < 100 and bunny_count < MAX_BUNNIES:
                bunnies[bunny_count].position = rl.get_mouse_position()
                bunnies[bunny_count].speed = rl.Vector2(
                    x = float<-rl.get_random_value(-250, 250),
                    y = float<-rl.get_random_value(-250, 250),
                )
                bunnies[bunny_count].color = random_bunny_color()
                bunny_count += 1
                spawn_index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            paused = not paused

        if not paused:
            let frame_time = rl.get_frame_time()
            var index = 0
            while index < bunny_count:
                bunnies[index].position.x += bunnies[index].speed.x * frame_time
                bunnies[index].position.y += bunnies[index].speed.y * frame_time

                if (bunnies[index].position.x + float<-bunny_texture.width / 2.0) > float<-rl.get_screen_width() or
                   (bunnies[index].position.x + float<-bunny_texture.width / 2.0) < 0.0:
                    bunnies[index].speed.x *= -1.0

                if (bunnies[index].position.y + float<-bunny_texture.height / 2.0) > float<-rl.get_screen_height() or
                   (bunnies[index].position.y + float<-bunny_texture.height / 2.0 - 40.0) < 0.0:
                    bunnies[index].speed.y *= -1.0

                index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < bunny_count:
            rl.draw_texture(
                bunny_texture,
                int<-bunnies[index].position.x,
                int<-bunnies[index].position.y,
                bunnies[index].color,
            )
            index += 1

        let bunny_count_text = rl.text_format("bunnies: %i", bunny_count)
        let draw_call_text = rl.text_format(
            "batched draw calls: %i",
            1 + (bunny_count / MAX_BATCH_ELEMENTS),
        )

        rl.draw_rectangle(0, 0, SCREEN_WIDTH, 40, rl.BLACK)
        rl.draw_text(bunny_count_text, 120, 10, 20, rl.GREEN)
        rl.draw_text(draw_call_text, 320, 10, 20, rl.MAROON)
        rl.draw_fps(10, 10)

        rl.end_drawing()

    return 0
