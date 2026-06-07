import std.math as math
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 720
const SCREEN_HEIGHT: int = 400
const LINE_LENGTH: float = 150.0
const DEG_TO_RAD: float = rl.PI / 180.0
const ANGLE_COUNT: int = 4


function angle_color(index: int) -> rl.Color:
    if index == 0:
        return rl.GREEN
    if index == 1:
        return rl.ORANGE
    if index == 2:
        return rl.BLUE
    if index == 3:
        return rl.MAGENTA
    return rl.WHITE


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - math angle rotation")
    defer rl.close_window()

    let center = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0)
    let angles = array[int, ANGLE_COUNT](0, 30, 60, 90)
    var total_angle: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        total_angle += 1.0
        if total_angle >= 360.0:
            total_angle -= 360.0

        rl.begin_drawing()
        rl.clear_background(rl.WHITE)
        rl.draw_text("Fixed angles + rotating line", 10, 10, 20, rl.LIGHTGRAY)

        var index = 0
        while index < ANGLE_COUNT:
            let radians = float<-angles[index] * DEG_TO_RAD
            let end_point = rl.Vector2(
                x = center.x + float<-math.cos(double<-radians) * LINE_LENGTH,
                y = center.y + float<-math.sin(double<-radians) * LINE_LENGTH
            )
            let color = angle_color(index)
            rl.draw_line_ex(center, end_point, 5.0, color)

            let text_position = rl.Vector2(
                x = center.x + float<-math.cos(double<-radians) * (LINE_LENGTH + 20.0),
                y = center.y + float<-math.sin(double<-radians) * (LINE_LENGTH + 20.0)
            )
            rl.draw_text(text.cstr_as_str(rl.text_format("%d°", angles[index])), int<-text_position.x, int<-text_position.y, 20, color)
            index += 1

        let animated_radians = total_angle * DEG_TO_RAD
        let animated_end = rl.Vector2(
            x = center.x + float<-math.cos(double<-animated_radians) * LINE_LENGTH,
            y = center.y + float<-math.sin(double<-animated_radians) * LINE_LENGTH
        )
        let animated_color = rl.color_from_hsv(total_angle, 0.8, 0.9)
        rl.draw_line_ex(center, animated_end, 5.0, animated_color)
        rl.end_drawing()

    return 0
