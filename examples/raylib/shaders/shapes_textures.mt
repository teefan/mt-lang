import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - shapes textures")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fudesumi = rl.load_texture("fudesumi.png")
    defer rl.unload_texture(fudesumi)
    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/grayscale.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("USING DEFAULT SHADER", 20, 40, 10, rl.RED)
        rl.draw_circle(80, 120, 35.0, rl.DARKBLUE)
        rl.draw_circle_gradient(rl.Vector2(x = 80.0, y = 220.0), 60.0, rl.GREEN, rl.SKYBLUE)
        rl.draw_circle_lines(80, 340, 80.0, rl.DARKBLUE)

        rl.begin_shader_mode(shader)
        rl.draw_text("USING CUSTOM SHADER", 190, 40, 10, rl.RED)
        rl.draw_rectangle(190, 90, 120, 60, rl.RED)
        rl.draw_rectangle_gradient_h(160, 170, 180, 130, rl.MAROON, rl.GOLD)
        rl.draw_rectangle_lines(210, 320, 80, 60, rl.ORANGE)
        rl.end_shader_mode()

        rl.draw_text("USING DEFAULT SHADER", 370, 40, 10, rl.RED)
        rl.draw_triangle(
            rl.Vector2(x = 430.0, y = 80.0),
            rl.Vector2(x = 370.0, y = 150.0),
            rl.Vector2(x = 490.0, y = 150.0),
            rl.VIOLET,
        )
        rl.draw_triangle_lines(
            rl.Vector2(x = 430.0, y = 160.0),
            rl.Vector2(x = 410.0, y = 230.0),
            rl.Vector2(x = 450.0, y = 230.0),
            rl.DARKBLUE,
        )
        rl.draw_poly(rl.Vector2(x = 430.0, y = 320.0), 6, 80.0, 0.0, rl.BROWN)

        rl.begin_shader_mode(shader)
        rl.draw_texture(fudesumi, 500, -30, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text("(c) Fudesumi sprite by Eiden Marsal", 380, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
