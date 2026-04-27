module examples.raylib.shaders.shaders_spotlight_rendering

import std.c.raylib as rl
import std.raylib.math as rm

struct Spot:
    position: rl.Vector2
    speed: rl.Vector2
    inner: f32
    radius: f32
    position_loc: i32
    inner_loc: i32
    radius_loc: i32

struct Star:
    position: rl.Vector2
    speed: rl.Vector2

const max_spots: i32 = 3
const max_stars: i32 = 400
const screen_width: i32 = 800
const screen_height: i32 = 450
const screen_width_f: f32 = 800.0
const screen_height_f: f32 = 450.0
const glsl_version: i32 = 330
const shader_path_format: cstr = c"resources/shaders/glsl%i/spotlight.fs"
const screen_width_uniform_name: cstr = c"screenWidth"
const move_text: cstr = c"Move the mouse!"
const pitch_black_text: cstr = c"Pitch Black"
const dark_text: cstr = c"Dark"
const raysan_path: cstr = c"resources/raysan.png"
const window_title: cstr = c"raylib [shaders] example - spotlight rendering"

def set_vec2_uniform(shader: rl.Shader, location: i32, vector: rl.Vector2) -> void:
    var values = array[f32, 2](vector.x, vector.y)
    rl.SetShaderValue(shader, location, raw(addr(values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

def set_float_uniform(shader: rl.Shader, location: i32, value: f32) -> void:
    var storage = value
    rl.SetShaderValue(shader, location, raw(addr(storage)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

def reset_star(star: ref[Star]) -> void:
    var current = value(star)
    current.position = rl.Vector2(x = screen_width_f / 2.0, y = screen_height_f / 2.0)
    current.speed.x = cast[f32](rl.GetRandomValue(-1000, 1000)) / 100.0
    current.speed.y = cast[f32](rl.GetRandomValue(-1000, 1000)) / 100.0

    while rm.abs(current.speed.x) + rm.abs(current.speed.y) <= 1.0:
        current.speed.x = cast[f32](rl.GetRandomValue(-1000, 1000)) / 100.0
        current.speed.y = cast[f32](rl.GetRandomValue(-1000, 1000)) / 100.0

    current.position = current.position.add(current.speed.multiply(rl.Vector2(x = 8.0, y = 8.0)))
    value(star) = current

def update_star(star: ref[Star]) -> void:
    var current = value(star)
    current.position = current.position.add(current.speed)

    if current.position.x < 0.0 or current.position.x > screen_width_f or current.position.y < 0.0 or current.position.y > screen_height_f:
        value(star) = current
        reset_star(star)
        return

    value(star) = current

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.HideCursor()

    let tex_ray = rl.LoadTexture(raysan_path)
    defer rl.UnloadTexture(tex_ray)

    var stars = zero[array[Star, max_stars]]()
    for index in range(0, max_stars):
        reset_star(addr(stars[index]))

    for _ in range(0, screen_width / 2):
        for index in range(0, max_stars):
            update_star(addr(stars[index]))

    var frame_counter = 0

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let position_names = array[cstr, max_spots](c"spots[0].pos", c"spots[1].pos", c"spots[2].pos")
    let inner_names = array[cstr, max_spots](c"spots[0].inner", c"spots[1].inner", c"spots[2].inner")
    let radius_names = array[cstr, max_spots](c"spots[0].radius", c"spots[1].radius", c"spots[2].radius")

    var spots = zero[array[Spot, max_spots]]()
    for index in range(0, max_spots):
        spots[index].position_loc = rl.GetShaderLocation(shader, position_names[index])
        spots[index].inner_loc = rl.GetShaderLocation(shader, inner_names[index])
        spots[index].radius_loc = rl.GetShaderLocation(shader, radius_names[index])

    let screen_width_loc = rl.GetShaderLocation(shader, screen_width_uniform_name)
    set_float_uniform(shader, screen_width_loc, screen_width_f)

    for index in range(0, max_spots):
        spots[index].position.x = cast[f32](rl.GetRandomValue(64, screen_width - 64))
        spots[index].position.y = cast[f32](rl.GetRandomValue(64, screen_height - 64))
        spots[index].speed = rl.Vector2(x = 0.0, y = 0.0)

        while rm.abs(spots[index].speed.x) + rm.abs(spots[index].speed.y) < 2.0:
            spots[index].speed.x = cast[f32](rl.GetRandomValue(-400, 40)) / 25.0
            spots[index].speed.y = cast[f32](rl.GetRandomValue(-400, 40)) / 25.0

        spots[index].inner = 28.0 * cast[f32](index + 1)
        spots[index].radius = 48.0 * cast[f32](index + 1)

        set_vec2_uniform(shader, spots[index].position_loc, spots[index].position)
        set_float_uniform(shader, spots[index].inner_loc, spots[index].inner)
        set_float_uniform(shader, spots[index].radius_loc, spots[index].radius)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frame_counter += 1

        for index in range(0, max_stars):
            update_star(addr(stars[index]))

        for index in range(0, max_spots):
            if index == 0:
                let mouse = rl.GetMousePosition()
                spots[index].position.x = mouse.x
                spots[index].position.y = screen_height_f - mouse.y
            else:
                spots[index].position.x += spots[index].speed.x
                spots[index].position.y += spots[index].speed.y

                if spots[index].position.x < 64.0:
                    spots[index].speed.x = -spots[index].speed.x
                if spots[index].position.x > screen_width_f - 64.0:
                    spots[index].speed.x = -spots[index].speed.x
                if spots[index].position.y < 64.0:
                    spots[index].speed.y = -spots[index].speed.y
                if spots[index].position.y > screen_height_f - 64.0:
                    spots[index].speed.y = -spots[index].speed.y

            set_vec2_uniform(shader, spots[index].position_loc, spots[index].position)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.DARKBLUE)

        for index in range(0, max_stars):
            rl.DrawRectangle(cast[i32](stars[index].position.x), cast[i32](stars[index].position.y), 2, 2, rl.WHITE)

        for index in range(0, 16):
            let phase = cast[f32](frame_counter + index * 8)
            let bob_x = cast[i32](screen_width_f / 2.0 + rm.cos(phase / 51.45) * (screen_width_f / 2.2) - 32.0)
            let bob_y = cast[i32](screen_height_f / 2.0 + rm.sin(phase / 17.87) * (screen_height_f / 4.2))
            rl.DrawTexture(tex_ray, bob_x, bob_y, rl.WHITE)

        rl.BeginShaderMode(shader)
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawFPS(10, 10)
        rl.DrawText(move_text, 10, 30, 20, rl.GREEN)
        rl.DrawText(pitch_black_text, cast[i32](screen_width_f * 0.2), screen_height / 2, 20, rl.GREEN)
        rl.DrawText(dark_text, cast[i32](screen_width_f * 0.66), screen_height / 2, 20, rl.GREEN)

    return 0
