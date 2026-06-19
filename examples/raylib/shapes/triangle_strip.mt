import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const POINT_CAPACITY: int = 122
const DEG_TO_RAD: float = rl.PI / 180.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - triangle strip")
    defer rl.close_window()

    var points: array[rl.Vector2, POINT_CAPACITY] = zero[array[rl.Vector2, POINT_CAPACITY]]
    let center = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0 - 125.0, y = float<-SCREEN_HEIGHT / 2.0)
    var segments: float = 6.0
    let inside_radius: float = 100.0
    let outside_radius: float = 150.0
    var outline = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let point_count = int<-segments
        let angle_step = (360.0 / float<-point_count) * DEG_TO_RAD

        var index = 0
        var point_index = 0
        while index < point_count:
            let angle1 = float<-index * angle_step
            points[point_index] = rl.Vector2(
                x = center.x + float<-math.cos(double<-angle1) * inside_radius,
                y = center.y + float<-math.sin(double<-angle1) * inside_radius
            )

            let angle2 = angle1 + (angle_step / 2.0)
            points[point_index + 1] = rl.Vector2(
                x = center.x + float<-math.cos(double<-angle2) * outside_radius,
                y = center.y + float<-math.sin(double<-angle2) * outside_radius
            )

            index += 1
            point_index += 2

        points[point_count * 2] = points[0]
        points[(point_count * 2) + 1] = points[1]

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        index = 0
        while index < point_count:
            let a = points[index * 2]
            let b = points[(index * 2) + 1]
            let c = points[(index * 2) + 2]
            let d = points[(index * 2) + 3]
            let angle1 = float<-index * angle_step
            rl.draw_triangle(c, b, a, rl.color_from_hsv(angle1 / DEG_TO_RAD, 1.0, 1.0))
            rl.draw_triangle(d, b, c, rl.color_from_hsv((angle1 + (angle_step / 2.0)) / DEG_TO_RAD, 1.0, 1.0))

            if outline:
                rl.draw_triangle_lines(a, b, c, rl.BLACK)
                rl.draw_triangle_lines(c, b, d, rl.BLACK)
            index += 1

        rl.draw_line(
            580,
            0,
            580,
            rl.get_screen_height(),
            rl.Color(r = 218ub, g = 218ub, b = 218ub, a = 255ub)
        )
        rl.draw_rectangle(
            580,
            0,
            rl.get_screen_width(),
            rl.get_screen_height(),
            rl.Color(r = 232ub, g = 232ub, b = 232ub, a = 255ub)
        )

        gui.slider_bar(
            rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0),
            "Segments",
            text.cstr_as_str(rl.text_format("%.0f", segments)),
            segments,
            6.0,
            60.0
        )
        gui.check_box(rl.Rectangle(x = 640.0, y = 70.0, width = 20.0, height = 20.0), "Outline", outline)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
