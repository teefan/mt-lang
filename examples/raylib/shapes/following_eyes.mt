import std.math as math
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - following eyes")
    defer rl.close_window()

    let sclera_left_position = rl.Vector2(x = float<-rl.get_screen_width() / 2.0 - 100.0, y = float<-rl.get_screen_height() / 2.0)
    let sclera_right_position = rl.Vector2(x = float<-rl.get_screen_width() / 2.0 + 100.0, y = float<-rl.get_screen_height() / 2.0)
    let sclera_radius: float = 80.0
    var iris_left_position = sclera_left_position
    var iris_right_position = sclera_right_position
    let iris_radius: float = 24.0
    var angle: float = 0.0
    var dx: float = 0.0
    var dy: float = 0.0
    var dxx: float = 0.0
    var dyy: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        iris_left_position = rl.get_mouse_position()
        iris_right_position = rl.get_mouse_position()

        if not rl.check_collision_point_circle(iris_left_position, sclera_left_position, sclera_radius - iris_radius):
            dx = iris_left_position.x - sclera_left_position.x
            dy = iris_left_position.y - sclera_left_position.y
            angle = float<-math.atan2(double<-dy, double<-dx)
            dxx = (sclera_radius - iris_radius) * float<-math.cos(double<-angle)
            dyy = (sclera_radius - iris_radius) * float<-math.sin(double<-angle)
            iris_left_position.x = sclera_left_position.x + dxx
            iris_left_position.y = sclera_left_position.y + dyy

        if not rl.check_collision_point_circle(iris_right_position, sclera_right_position, sclera_radius - iris_radius):
            dx = iris_right_position.x - sclera_right_position.x
            dy = iris_right_position.y - sclera_right_position.y
            angle = float<-math.atan2(double<-dy, double<-dx)
            dxx = (sclera_radius - iris_radius) * float<-math.cos(double<-angle)
            dyy = (sclera_radius - iris_radius) * float<-math.sin(double<-angle)
            iris_right_position.x = sclera_right_position.x + dxx
            iris_right_position.y = sclera_right_position.y + dyy

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_circle_v(sclera_left_position, sclera_radius, rl.LIGHTGRAY)
        rl.draw_circle_v(iris_left_position, iris_radius, rl.BROWN)
        rl.draw_circle_v(iris_left_position, 10.0, rl.BLACK)
        rl.draw_circle_v(sclera_right_position, sclera_radius, rl.LIGHTGRAY)
        rl.draw_circle_v(iris_right_position, iris_radius, rl.DARKGREEN)
        rl.draw_circle_v(iris_right_position, 10.0, rl.BLACK)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
