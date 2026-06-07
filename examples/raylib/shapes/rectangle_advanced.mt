import std.math as math
import std.raylib as rl
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RECT_POINT_COUNT: int = 12


function draw_rectangle_rounded_gradient_h(
    rec: rl.Rectangle,
    roundness_left: float,
    roundness_right: float,
    segments: int,
    left: rl.Color,
    right: rl.Color
) -> void:
    if (roundness_left <= 0.0 and roundness_right <= 0.0) or rec.width < 1.0 or rec.height < 1.0:
        rl.draw_rectangle_gradient_ex(rec, left, left, right, right)
        return

    var clamped_roundness_left = roundness_left
    if clamped_roundness_left >= 1.0:
        clamped_roundness_left = 1.0

    var clamped_roundness_right = roundness_right
    if clamped_roundness_right >= 1.0:
        clamped_roundness_right = 1.0

    let rec_size = if rec.width > rec.height: rec.height else: rec.width
    var radius_left = (rec_size * clamped_roundness_left) / 2.0
    var radius_right = (rec_size * clamped_roundness_right) / 2.0
    if radius_left <= 0.0:
        radius_left = 0.0
    if radius_right <= 0.0:
        radius_right = 0.0
    if radius_left <= 0.0 and radius_right <= 0.0:
        return

    let step_length = 90.0 / float<-segments

    let point = array[rl.Vector2, RECT_POINT_COUNT](
        rl.Vector2(x = rec.x + radius_left, y = rec.y),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y),
        rl.Vector2(x = rec.x + rec.width, y = rec.y + radius_right),
        rl.Vector2(x = rec.x + rec.width, y = rec.y + rec.height - radius_right),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + rec.height),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + rec.height),
        rl.Vector2(x = rec.x, y = rec.y + rec.height - radius_left),
        rl.Vector2(x = rec.x, y = rec.y + radius_left),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + radius_left),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + radius_right),
        rl.Vector2(x = rec.x + rec.width - radius_right, y = rec.y + rec.height - radius_right),
        rl.Vector2(x = rec.x + radius_left, y = rec.y + rec.height - radius_left)
    )

    let centers = array[rl.Vector2, 4](point[8], point[9], point[10], point[11])
    let angles = array[float, 4](180.0, 270.0, 0.0, 90.0)

    rlgl.begin(rlgl.RL_TRIANGLES)

    var corner_index = 0
    while corner_index < 4:
        let color = if corner_index == 0 or corner_index == 3: left else: right
        let radius = if corner_index == 0 or corner_index == 3: radius_left else: radius_right
        var angle = angles[corner_index]
        let center = centers[corner_index]

        var segment = 0
        while segment < segments:
            rlgl.color4ub(color.r, color.g, color.b, color.a)
            rlgl.vertex2f(center.x, center.y)
            rlgl.vertex2f(
                float<-(center.x + float<-math.cos(double<-((angle + step_length) * rl.PI / 180.0)) * radius),
                float<-(center.y + float<-math.sin(double<-((angle + step_length) * rl.PI / 180.0)) * radius)
            )
            rlgl.vertex2f(
                float<-(center.x + float<-math.cos(double<-(angle * rl.PI / 180.0)) * radius),
                float<-(center.y + float<-math.sin(double<-(angle * rl.PI / 180.0)) * radius)
            )
            angle += step_length
            segment += 1
        corner_index += 1

    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[0].x, point[0].y)
    rlgl.vertex2f(point[8].x, point[8].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[9].x, point[9].y)
    rlgl.vertex2f(point[1].x, point[1].y)
    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[0].x, point[0].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[9].x, point[9].y)

    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[9].x, point[9].y)
    rlgl.vertex2f(point[10].x, point[10].y)
    rlgl.vertex2f(point[3].x, point[3].y)
    rlgl.vertex2f(point[2].x, point[2].y)
    rlgl.vertex2f(point[9].x, point[9].y)
    rlgl.vertex2f(point[3].x, point[3].y)

    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[11].x, point[11].y)
    rlgl.vertex2f(point[5].x, point[5].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[4].x, point[4].y)
    rlgl.vertex2f(point[10].x, point[10].y)
    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[11].x, point[11].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[4].x, point[4].y)

    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[7].x, point[7].y)
    rlgl.vertex2f(point[6].x, point[6].y)
    rlgl.vertex2f(point[11].x, point[11].y)
    rlgl.vertex2f(point[8].x, point[8].y)
    rlgl.vertex2f(point[7].x, point[7].y)
    rlgl.vertex2f(point[11].x, point[11].y)

    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[8].x, point[8].y)
    rlgl.vertex2f(point[11].x, point[11].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[10].x, point[10].y)
    rlgl.vertex2f(point[9].x, point[9].y)
    rlgl.color4ub(left.r, left.g, left.b, left.a)
    rlgl.vertex2f(point[8].x, point[8].y)
    rlgl.color4ub(right.r, right.g, right.b, right.a)
    rlgl.vertex2f(point[10].x, point[10].y)

    rlgl.end()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - rectangle advanced")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let width = float<-rl.get_screen_width() / 2.0
        let height = float<-rl.get_screen_height() / 6.0
        var rec = rl.Rectangle(
            x = float<-rl.get_screen_width() / 2.0 - width / 2.0,
            y = float<-rl.get_screen_height() / 2.0 - 5.0 * (height / 2.0),
            width = width,
            height = height
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        draw_rectangle_rounded_gradient_h(rec, 0.8, 0.8, 36, rl.BLUE, rl.RED)
        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 0.5, 1.0, 36, rl.RED, rl.PINK)
        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 1.0, 0.5, 36, rl.RED, rl.BLUE)
        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 0.0, 1.0, 36, rl.BLUE, rl.BLACK)
        rec.y += rec.height + 1.0
        draw_rectangle_rounded_gradient_h(rec, 1.0, 0.0, 36, rl.BLUE, rl.PINK)

        rl.end_drawing()

    return 0
