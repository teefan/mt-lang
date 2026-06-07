import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - collision area")
    defer rl.close_window()

    var box_a = rl.Rectangle(x = 10.0, y = float<-rl.get_screen_height() / 2.0 - 50.0, width = 200.0, height = 100.0)
    var box_a_speed_x = 4
    var box_b = rl.Rectangle(
        x = float<-rl.get_screen_width() / 2.0 - 30.0,
        y = float<-rl.get_screen_height() / 2.0 - 30.0,
        width = 60.0,
        height = 60.0
    )
    var box_collision = zero[rl.Rectangle]
    let screen_upper_limit = 40
    var pause = false
    var collision = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if not pause:
            box_a.x += float<-box_a_speed_x

        if (box_a.x + box_a.width) >= float<-rl.get_screen_width() or box_a.x <= 0.0:
            box_a_speed_x *= -1

        let mouse_position = rl.get_mouse_position()
        box_b.x = mouse_position.x - (box_b.width / 2.0)
        box_b.y = mouse_position.y - (box_b.height / 2.0)

        if (box_b.x + box_b.width) >= float<-rl.get_screen_width():
            box_b.x = float<-rl.get_screen_width() - box_b.width
        else if box_b.x <= 0.0:
            box_b.x = 0.0

        if (box_b.y + box_b.height) >= float<-rl.get_screen_height():
            box_b.y = float<-rl.get_screen_height() - box_b.height
        else if box_b.y <= float<-screen_upper_limit:
            box_b.y = float<-screen_upper_limit

        collision = rl.check_collision_recs(box_a, box_b)
        if collision:
            box_collision = rl.get_collision_rec(box_a, box_b)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle(0, 0, SCREEN_WIDTH, screen_upper_limit, if collision: rl.RED else: rl.BLACK)
        rl.draw_rectangle_rec(box_a, rl.GOLD)
        rl.draw_rectangle_rec(box_b, rl.BLUE)

        if collision:
            rl.draw_rectangle_rec(box_collision, rl.LIME)
            rl.draw_text(
                "COLLISION!",
                (rl.get_screen_width() / 2) - (rl.measure_text("COLLISION!", 20) / 2),
                (screen_upper_limit / 2) - 10,
                20,
                rl.BLACK
            )
            rl.draw_text(
                text.cstr_as_str(rl.text_format(
                    "Collision Area: %i",
                    int<-box_collision.width * int<-box_collision.height
                )),
                (rl.get_screen_width() / 2) - 100,
                screen_upper_limit + 10,
                20,
                rl.BLACK
            )

        rl.draw_text("Press SPACE to PAUSE/RESUME", 20, SCREEN_HEIGHT - 35, 20, rl.LIGHTGRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
