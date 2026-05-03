module examples.idiomatic.raylib.rectangle_scaling

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const handle_size: f32 = 12.0


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Rectangle Scaling")
    defer rl.close_window()

    var rectangle = rl.Rectangle(x = 100.0, y = 100.0, width = 200.0, height = 80.0)
    var mouse_position = zero[rl.Vector2]()
    var handle_hovered = false
    var scaling = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_position = rl.get_mouse_position()

        let scale_handle = rl.Rectangle(
            x = rectangle.x + rectangle.width - handle_size,
            y = rectangle.y + rectangle.height - handle_size,
            width = handle_size,
            height = handle_size,
        )

        handle_hovered = rl.check_collision_point_rec(mouse_position, scale_handle)
        if handle_hovered and rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            scaling = true

        if scaling:
            handle_hovered = true
            rectangle.width = mouse_position.x - rectangle.x
            rectangle.height = mouse_position.y - rectangle.y

            if rectangle.width < handle_size:
                rectangle.width = handle_size
            if rectangle.height < handle_size:
                rectangle.height = handle_size

            let window_width = f32<-rl.get_screen_width()
            let window_height = f32<-rl.get_screen_height()
            if rectangle.width > window_width - rectangle.x:
                rectangle.width = window_width - rectangle.x
            if rectangle.height > window_height - rectangle.y:
                rectangle.height = window_height - rectangle.y

            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                scaling = false

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Scale rectangle dragging from bottom-right corner!", 10, 10, 20, rl.GRAY)
        rl.draw_rectangle_rec(rectangle, rl.fade(rl.GREEN, 0.5))

        if handle_hovered:
            rl.draw_rectangle_lines_ex(rectangle, 1.0, rl.RED)
            rl.draw_triangle(
                rl.Vector2(x = rectangle.x + rectangle.width - handle_size, y = rectangle.y + rectangle.height),
                rl.Vector2(x = rectangle.x + rectangle.width, y = rectangle.y + rectangle.height),
                rl.Vector2(x = rectangle.x + rectangle.width, y = rectangle.y + rectangle.height - handle_size),
                rl.RED,
            )

    return 0
