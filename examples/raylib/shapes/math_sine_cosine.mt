import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.raymath as rm
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const WAVE_POINTS: int = 36
const DEG_TO_RAD: float = rl.PI / 180.0


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - math sine cosine")
    defer rl.close_window()

    var sine_points: array[rl.Vector2, WAVE_POINTS] = zero[array[rl.Vector2, WAVE_POINTS]]
    var cos_points: array[rl.Vector2, WAVE_POINTS] = zero[array[rl.Vector2, WAVE_POINTS]]
    let center = rl.Vector2(x = float<-(float<-SCREEN_WIDTH / 2.0 - 30.0), y = float<-(float<-SCREEN_HEIGHT / 2.0))
    let graph_bounds = rl.Rectangle(x = 20.0, y = float<-SCREEN_HEIGHT - 120.0, width = 200.0, height = 100.0)
    let half_graph_height = graph_bounds.height / 2.0
    let radius: float = 130.0
    var angle: float = 0.0
    var pause = false

    var index = 0
    while index < WAVE_POINTS:
        let t = float<-index / float<-(WAVE_POINTS - 1)
        let current_angle = t * 360.0 * DEG_TO_RAD
        sine_points[index] = rl.Vector2(
            x = float<-(graph_bounds.x + t * graph_bounds.width),
            y = float<-(graph_bounds.y + half_graph_height - float<-math.sin(double<-current_angle) * half_graph_height)
        )
        cos_points[index] = rl.Vector2(
            x = float<-(graph_bounds.x + t * graph_bounds.width),
            y = float<-(graph_bounds.y + half_graph_height - float<-math.cos(double<-current_angle) * half_graph_height)
        )
        index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let angle_rad = angle * DEG_TO_RAD
        let cos_rad = float<-math.cos(double<-angle_rad)
        let sin_rad = float<-math.sin(double<-angle_rad)

        let point = rl.Vector2(x = float<-(center.x + cos_rad * radius), y = float<-(center.y - sin_rad * radius))
        let limit_min = rl.Vector2(x = float<-(center.x - radius), y = float<-(center.y - radius))
        let limit_max = rl.Vector2(x = float<-(center.x + radius), y = float<-(center.y + radius))

        let complementary = 90.0 - angle
        let supplementary = 180.0 - angle
        let explementary = 360.0 - angle

        let tangent = rm.clamp(float<-math.tan(double<-angle_rad), -10.0, 10.0)
        let cotangent = if tangent > 0.001 or tangent < -0.001: rm.clamp(1.0 / tangent, -radius, radius) else: 0.0
        let tangent_point = rl.Vector2(x = float<-(center.x + radius), y = float<-(center.y - tangent * radius))
        let cotangent_point = rl.Vector2(x = float<-(center.x + cotangent * radius), y = float<-(center.y - radius))

        angle = rm.wrap(angle + (if not pause: 1.0 else: 0.0), 0.0, 360.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_line_ex(
            rl.Vector2(x = float<-center.x, y = float<-limit_min.y),
            rl.Vector2(x = float<-cotangent_point.x, y = float<-limit_min.y),
            2.0,
            rl.ORANGE
        )
        rl.draw_line_dashed(center, cotangent_point, 10, 4, rl.ORANGE)

        rl.draw_line(
            580,
            0,
            580,
            rl.get_screen_height(),
            rl.Color(r = ubyte<-218, g = ubyte<-218, b = ubyte<-218, a = ubyte<-255)
        )
        rl.draw_rectangle(
            580,
            0,
            rl.get_screen_width(),
            rl.get_screen_height(),
            rl.Color(r = ubyte<-232, g = ubyte<-232, b = ubyte<-232, a = ubyte<-255)
        )

        rl.draw_circle_lines_v(center, radius, rl.GRAY)
        rl.draw_line_ex(
            rl.Vector2(x = float<-center.x, y = float<-limit_min.y),
            rl.Vector2(x = float<-center.x, y = float<-limit_max.y),
            1.0,
            rl.GRAY
        )
        rl.draw_line_ex(
            rl.Vector2(x = float<-limit_min.x, y = float<-center.y),
            rl.Vector2(x = float<-limit_max.x, y = float<-center.y),
            1.0,
            rl.GRAY
        )

        rl.draw_line_ex(
            rl.Vector2(x = float<-graph_bounds.x, y = float<-graph_bounds.y),
            rl.Vector2(x = float<-graph_bounds.x, y = float<-(graph_bounds.y + graph_bounds.height)),
            2.0,
            rl.GRAY
        )
        rl.draw_line_ex(
            rl.Vector2(x = float<-(graph_bounds.x + graph_bounds.width), y = float<-graph_bounds.y),
            rl.Vector2(
                x = float<-(graph_bounds.x + graph_bounds.width),
                y = float<-(graph_bounds.y + graph_bounds.height)
            ),
            2.0,
            rl.GRAY
        )
        rl.draw_line_ex(
            rl.Vector2(x = float<-graph_bounds.x, y = float<-(graph_bounds.y + half_graph_height)),
            rl.Vector2(
                x = float<-(graph_bounds.x + graph_bounds.width),
                y = float<-(graph_bounds.y + half_graph_height)
            ),
            2.0,
            rl.GRAY
        )

        rl.draw_text("1", int<-graph_bounds.x - 8, int<-graph_bounds.y, 6, rl.GRAY)
        rl.draw_text("0", int<-graph_bounds.x - 8, int<-(graph_bounds.y + half_graph_height) - 6, 6, rl.GRAY)
        rl.draw_text("-1", int<-graph_bounds.x - 12, int<-(graph_bounds.y + graph_bounds.height) - 8, 6, rl.GRAY)
        rl.draw_text("0", int<-graph_bounds.x - 2, int<-(graph_bounds.y + graph_bounds.height) + 4, 6, rl.GRAY)
        rl.draw_text(
            "360",
            int<-(graph_bounds.x + graph_bounds.width) - 8,
            int<-(graph_bounds.y + graph_bounds.height) + 4,
            6,
            rl.GRAY
        )

        rl.draw_line_ex(
            rl.Vector2(x = float<-center.x, y = float<-center.y),
            rl.Vector2(x = float<-center.x, y = float<-point.y),
            2.0,
            rl.RED
        )
        rl.draw_line_dashed(
            rl.Vector2(x = float<-point.x, y = float<-center.y),
            rl.Vector2(x = float<-point.x, y = float<-point.y),
            10,
            4,
            rl.RED
        )
        rl.draw_text(text.cstr_as_str(rl.text_format("Sine %.2f", sin_rad)), 640, 190, 6, rl.RED)
        rl.draw_circle_v(
            rl.Vector2(
                x = float<-(graph_bounds.x + (angle / 360.0) * graph_bounds.width),
                y = float<-(graph_bounds.y + ((-sin_rad + 1.0) * half_graph_height))
            ),
            4.0,
            rl.RED
        )
        rl.draw_spline_linear_ptr(ptr_of(sine_points[0]), WAVE_POINTS, 1.0, rl.RED)

        rl.draw_line_ex(
            rl.Vector2(x = float<-center.x, y = float<-center.y),
            rl.Vector2(x = float<-point.x, y = float<-center.y),
            2.0,
            rl.BLUE
        )
        rl.draw_line_dashed(
            rl.Vector2(x = float<-center.x, y = float<-point.y),
            rl.Vector2(x = float<-point.x, y = float<-point.y),
            10,
            4,
            rl.BLUE
        )
        rl.draw_text(text.cstr_as_str(rl.text_format("Cosine %.2f", cos_rad)), 640, 210, 6, rl.BLUE)
        rl.draw_circle_v(
            rl.Vector2(
                x = float<-(graph_bounds.x + (angle / 360.0) * graph_bounds.width),
                y = float<-(graph_bounds.y + ((-cos_rad + 1.0) * half_graph_height))
            ),
            4.0,
            rl.BLUE
        )
        rl.draw_spline_linear_ptr(ptr_of(cos_points[0]), WAVE_POINTS, 1.0, rl.BLUE)

        rl.draw_line_ex(
            rl.Vector2(x = float<-limit_max.x, y = float<-center.y),
            rl.Vector2(x = float<-limit_max.x, y = float<-tangent_point.y),
            2.0,
            rl.PURPLE
        )
        rl.draw_line_dashed(center, tangent_point, 10, 4, rl.PURPLE)
        rl.draw_text(text.cstr_as_str(rl.text_format("Tangent %.2f", tangent)), 640, 230, 6, rl.PURPLE)
        rl.draw_text(text.cstr_as_str(rl.text_format("Cotangent %.2f", cotangent)), 640, 250, 6, rl.ORANGE)

        rl.draw_circle_sector_lines(center, radius * 0.6, -angle, -90.0, 36, rl.BEIGE)
        rl.draw_text(text.cstr_as_str(rl.text_format("Complementary %.0f deg", complementary)), 640, 150, 6, rl.BEIGE)

        rl.draw_circle_sector_lines(center, radius * 0.5, -angle, -180.0, 36, rl.DARKBLUE)
        rl.draw_text(
            text.cstr_as_str(rl.text_format("Supplementary %.0f deg", supplementary)),
            640,
            130,
            6,
            rl.DARKBLUE
        )

        rl.draw_circle_sector_lines(center, radius * 0.4, -angle, -360.0, 36, rl.PINK)
        rl.draw_text(text.cstr_as_str(rl.text_format("Explementary %.0f deg", explementary)), 640, 170, 6, rl.PINK)

        rl.draw_circle_sector_lines(center, radius * 0.7, -angle, 0.0, 36, rl.LIME)
        rl.draw_line_ex(rl.Vector2(x = float<-center.x, y = float<-center.y), point, 2.0, rl.BLACK)
        rl.draw_circle_v(point, 4.0, rl.BLACK)

        gui.toggle(rl.Rectangle(x = 640.0, y = 70.0, width = 120.0, height = 20.0), "Pause", pause)
        gui.slider_bar(
            rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0),
            "Angle",
            text.cstr_as_str(rl.text_format("%.0f deg", angle)),
            angle,
            0.0,
            360.0
        )
        gui.group_box(rl.Rectangle(x = 620.0, y = 110.0, width = 140.0, height = 170.0), "Angle Values")

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
