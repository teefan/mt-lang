import std.math as math
import std.raylib as rl
import std.raymath as raymath

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_BUILDINGS: int = 100


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 2d camera")
    defer rl.close_window()

    var player = rl.Rectangle(x = 400.0, y = 280.0, width = 40.0, height = 40.0)
    var buildings: array[rl.Rectangle, MAX_BUILDINGS] = zero[array[rl.Rectangle, MAX_BUILDINGS]]
    var building_colors: array[rl.Color, MAX_BUILDINGS] = zero[array[rl.Color, MAX_BUILDINGS]]

    var spacing = 0
    var building_index = 0
    while building_index < MAX_BUILDINGS:
        buildings[building_index].width = float<-rl.get_random_value(50, 200)
        buildings[building_index].height = float<-rl.get_random_value(100, 800)
        buildings[building_index].y = (float<-SCREEN_HEIGHT) - 130.0 - buildings[building_index].height
        buildings[building_index].x = -6000.0 + (float<-spacing)

        spacing += int<-buildings[building_index].width
        building_colors[building_index] = rl.Color(
            r = ubyte<-rl.get_random_value(200, 240),
            g = ubyte<-rl.get_random_value(200, 240),
            b = ubyte<-rl.get_random_value(200, 250),
            a = ubyte<-255
        )
        building_index += 1

    var camera = rl.Camera2D(
        target = rl.Vector2(x = player.x + 20.0, y = player.y + 20.0),
        offset = rl.Vector2(x = (float<-SCREEN_WIDTH) / 2.0, y = (float<-SCREEN_HEIGHT) / 2.0),
        rotation = 0.0,
        zoom = 1.0
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            player.x += 2.0
        else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            player.x -= 2.0

        camera.target = rl.Vector2(x = player.x + 20.0, y = player.y + 20.0)

        if rl.is_key_down(rl.KeyboardKey.KEY_A):
            camera.rotation -= 1.0
        else if rl.is_key_down(rl.KeyboardKey.KEY_S):
            camera.rotation += 1.0

        if camera.rotation > 40.0:
            camera.rotation = 40.0
        else if camera.rotation < -40.0:
            camera.rotation = -40.0

        camera.zoom = float<-math.exp(math.log(double<-camera.zoom) + double<-(rl.get_mouse_wheel_move() * 0.1))
        camera.zoom = raymath.clamp(camera.zoom, 0.1, 3.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            camera.zoom = 1.0
            camera.rotation = 0.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_2d(camera)
        rl.draw_rectangle(-6000, 320, 13000, 8000, rl.DARKGRAY)

        building_index = 0
        while building_index < MAX_BUILDINGS:
            rl.draw_rectangle_rec(buildings[building_index], building_colors[building_index])
            building_index += 1

        rl.draw_rectangle_rec(player, rl.RED)
        rl.draw_line(int<-camera.target.x, -SCREEN_HEIGHT * 10, int<-camera.target.x, SCREEN_HEIGHT * 10, rl.GREEN)
        rl.draw_line(-SCREEN_WIDTH * 10, int<-camera.target.y, SCREEN_WIDTH * 10, int<-camera.target.y, rl.GREEN)
        rl.end_mode_2d()

        rl.draw_text("SCREEN AREA", 640, 10, 20, rl.RED)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, 5, rl.RED)
        rl.draw_rectangle(0, 5, 5, SCREEN_HEIGHT - 10, rl.RED)
        rl.draw_rectangle(SCREEN_WIDTH - 5, 5, 5, SCREEN_HEIGHT - 10, rl.RED)
        rl.draw_rectangle(0, SCREEN_HEIGHT - 5, SCREEN_WIDTH, 5, rl.RED)

        rl.draw_rectangle_rec(rl.Rectangle(x = 10.0, y = 10.0, width = 250.0, height = 113.0), rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(10, 10, 250, 113, rl.BLUE)

        rl.draw_text("Free 2D camera controls:", 20, 20, 10, rl.BLACK)
        rl.draw_text("- Right/Left to move player", 40, 40, 10, rl.DARKGRAY)
        rl.draw_text("- Mouse Wheel to Zoom in-out", 40, 60, 10, rl.DARKGRAY)
        rl.draw_text("- A / S to Rotate", 40, 80, 10, rl.DARKGRAY)
        rl.draw_text("- R to reset Zoom and Rotation", 40, 100, 10, rl.DARKGRAY)

        rl.end_drawing()

    return 0
