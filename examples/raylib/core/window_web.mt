import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function update_draw_frame() -> void:
    rl.begin_drawing()
    rl.clear_background(rl.RAYWHITE)
    rl.draw_text("Welcome to raylib web structure!", 220, 200, 20, rl.SKYBLUE)
    rl.end_drawing()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - window web")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        update_draw_frame()

    return 0
