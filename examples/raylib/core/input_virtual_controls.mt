import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BUTTON_NONE: int = -1
const BUTTON_UP: int = 0
const BUTTON_LEFT: int = 1
const BUTTON_RIGHT: int = 2
const BUTTON_DOWN: int = 3
const BUTTON_MAX: int = 4
const ARROW_SIDE: float = 9.0
const ARROW_TIP: float = 12.0


function abs_float(value: float) -> float:
    if value < 0.0:
        return -value

    return value


function draw_pad_button(
    position: rl.Vector2,
    button_radius: float,
    button: int,
    pressed_button: int,
    arrow_color: rl.Color
) -> void:
    let circle_color = if button == pressed_button: rl.DARKGRAY else: rl.BLACK
    rl.draw_circle_v(position, button_radius, circle_color)

    if button == BUTTON_UP:
        rl.draw_triangle(
            rl.Vector2(x = position.x, y = position.y - ARROW_TIP),
            rl.Vector2(x = position.x - ARROW_SIDE, y = position.y + ARROW_SIDE),
            rl.Vector2(x = position.x + ARROW_SIDE, y = position.y + ARROW_SIDE),
            arrow_color
        )
    else if button == BUTTON_LEFT:
        rl.draw_triangle(
            rl.Vector2(x = position.x + ARROW_SIDE, y = position.y - ARROW_SIDE),
            rl.Vector2(x = position.x - ARROW_TIP, y = position.y),
            rl.Vector2(x = position.x + ARROW_SIDE, y = position.y + ARROW_SIDE),
            arrow_color
        )
    else if button == BUTTON_RIGHT:
        rl.draw_triangle(
            rl.Vector2(x = position.x + ARROW_TIP, y = position.y),
            rl.Vector2(x = position.x - ARROW_SIDE, y = position.y - ARROW_SIDE),
            rl.Vector2(x = position.x - ARROW_SIDE, y = position.y + ARROW_SIDE),
            arrow_color
        )
    else:
        rl.draw_triangle(
            rl.Vector2(x = position.x - ARROW_SIDE, y = position.y - ARROW_SIDE),
            rl.Vector2(x = position.x, y = position.y + ARROW_TIP),
            rl.Vector2(x = position.x + ARROW_SIDE, y = position.y - ARROW_SIDE),
            arrow_color
        )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input virtual controls")
    defer rl.close_window()

    let pad_position = rl.Vector2(x = 100.0, y = 350.0)
    let button_radius: float = 30.0
    let button_step: float = button_radius * (float<-1.5)
    let button_positions = array[rl.Vector2, 4](
        rl.Vector2(x = pad_position.x, y = pad_position.y - button_step),
        rl.Vector2(x = pad_position.x - button_step, y = pad_position.y),
        rl.Vector2(x = pad_position.x + button_step, y = pad_position.y),
        rl.Vector2(x = pad_position.x, y = pad_position.y + button_step)
    )
    let button_label_colors = array[rl.Color, 4](rl.YELLOW, rl.BLUE, rl.RED, rl.GREEN)

    var pressed_button = BUTTON_NONE
    var input_position = rl.Vector2(x = 0.0, y = 0.0)
    var player_position = rl.Vector2(x = float<-(SCREEN_WIDTH / 2), y = float<-(SCREEN_HEIGHT / 2))
    let player_speed: float = 75.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.get_touch_point_count() > 0:
            input_position = rl.get_touch_position(0)
        else:
            input_position = rl.get_mouse_position()

        pressed_button = BUTTON_NONE
        if (
            rl.get_touch_point_count() > 0
            or (rl.get_touch_point_count() == 0 and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT))
        ):
            var index = 0
            while index < BUTTON_MAX:
                let dist_x = abs_float(button_positions[index].x - input_position.x)
                let dist_y = abs_float(button_positions[index].y - input_position.y)
                if dist_x + dist_y < button_radius:
                    pressed_button = index
                    break
                index += 1

        if pressed_button == BUTTON_UP:
            player_position.y -= player_speed * rl.get_frame_time()
        else if pressed_button == BUTTON_LEFT:
            player_position.x -= player_speed * rl.get_frame_time()
        else if pressed_button == BUTTON_RIGHT:
            player_position.x += player_speed * rl.get_frame_time()
        else if pressed_button == BUTTON_DOWN:
            player_position.y += player_speed * rl.get_frame_time()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_circle_v(player_position, 50.0, rl.MAROON)

        var index = 0
        while index < BUTTON_MAX:
            draw_pad_button(button_positions[index], button_radius, index, pressed_button, button_label_colors[index])
            index += 1

        rl.draw_text("move the player with D-Pad buttons", 10, 10, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
