import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - scissor test")
    defer rl.close_window()

    var scissor_area = rl.Rectangle(x = 0.0, y = 0.0, width = 300.0, height = 300.0)
    var scissor_mode = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            scissor_mode = not scissor_mode

        scissor_area.x = (float<-rl.get_mouse_x()) - scissor_area.width / 2.0
        scissor_area.y = (float<-rl.get_mouse_y()) - scissor_area.height / 2.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if scissor_mode:
            rl.begin_scissor_mode(int<-scissor_area.x, int<-scissor_area.y, int<-scissor_area.width, int<-scissor_area.height)

        rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.RED)
        rl.draw_text("Move the mouse around to reveal this text!", 190, 200, 20, rl.LIGHTGRAY)

        if scissor_mode:
            rl.end_scissor_mode()

        rl.draw_rectangle_lines_ex(scissor_area, 1.0, rl.BLACK)
        rl.draw_text("Press S to toggle scissor test", 10, 10, 20, rl.BLACK)

        rl.end_drawing()

    return 0
