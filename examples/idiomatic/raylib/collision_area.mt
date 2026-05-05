module examples.idiomatic.raylib.collision_area

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const screen_upper_limit: int = 40


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Collision Area")
    defer rl.close_window()

    var moving_box = rl.Rectangle(
        x = 10.0,
        y = float<-screen_height / 2.0 - 50.0,
        width = 200.0,
        height = 100.0,
    )
    var moving_speed_x: float = 4.0
    var mouse_box = rl.Rectangle(
        x = float<-screen_width / 2.0 - 30.0,
        y = float<-screen_height / 2.0 - 30.0,
        width = 60.0,
        height = 60.0,
    )
    var overlap = zero[rl.Rectangle]
    var paused = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            paused = not paused

        if not paused:
            moving_box.x += moving_speed_x

        let window_width = float<-rl.get_screen_width()
        let window_height = float<-rl.get_screen_height()
        let top_limit = float<-screen_upper_limit

        if moving_box.x + moving_box.width >= window_width or moving_box.x <= 0.0:
            moving_speed_x = -moving_speed_x

        mouse_box.x = float<-rl.get_mouse_x() - mouse_box.width / 2.0
        mouse_box.y = float<-rl.get_mouse_y() - mouse_box.height / 2.0

        if mouse_box.x + mouse_box.width >= window_width:
            mouse_box.x = window_width - mouse_box.width
        elif mouse_box.x <= 0.0:
            mouse_box.x = 0.0

        if mouse_box.y + mouse_box.height >= window_height:
            mouse_box.y = window_height - mouse_box.height
        elif mouse_box.y <= top_limit:
            mouse_box.y = top_limit

        let colliding = rl.check_collision_recs(moving_box, mouse_box)
        if colliding:
            overlap = rl.get_collision_rec(moving_box, mouse_box)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle(0, 0, screen_width, screen_upper_limit, if colliding: rl.RED else: rl.BLACK)
        rl.draw_rectangle_rec(moving_box, rl.GOLD)
        rl.draw_rectangle_rec(mouse_box, rl.BLUE)

        if colliding:
            rl.draw_rectangle_rec(overlap, rl.LIME)
            let label = "COLLISION!"
            rl.draw_text(label, rl.get_screen_width() / 2 - rl.measure_text(label, 20) / 2, screen_upper_limit / 2 - 10, 20, rl.BLACK)
            let area = int<-overlap.width * int<-overlap.height
            rl.draw_text(rl.text_format_int("Collision Area: %i", area), rl.get_screen_width() / 2 - 100, screen_upper_limit + 10, 20, rl.BLACK)

        rl.draw_text("Press SPACE to pause or resume", 20, screen_height - 35, 20, rl.LIGHTGRAY)
        rl.draw_fps(10, 10)

    return 0
