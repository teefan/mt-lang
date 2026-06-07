import std.raylib as rl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - lines drawing")
    defer rl.close_window()

    var start_text = true
    var mouse_position_previous = rl.get_mouse_position()
    let canvas = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(canvas)
    var line_thickness: float = 8.0
    var line_hue: float = 0.0

    rl.begin_texture_mode(canvas)
    rl.clear_background(rl.RAYWHITE)
    rl.end_texture_mode()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and start_text:
            start_text = false

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            rl.begin_texture_mode(canvas)
            rl.clear_background(rl.RAYWHITE)
            rl.end_texture_mode()

        let left_button_down = rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT)
        let right_button_down = rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT)

        if left_button_down or right_button_down:
            var draw_color = rl.WHITE
            let mouse_position = rl.get_mouse_position()

            if left_button_down:
                line_hue += rm.vector2_distance(mouse_position_previous, mouse_position) / 3.0
                while line_hue >= 360.0:
                    line_hue -= 360.0
                draw_color = rl.color_from_hsv(line_hue, 1.0, 1.0)
            else if right_button_down:
                draw_color = rl.RAYWHITE

            rl.begin_texture_mode(canvas)
            rl.draw_circle_v(mouse_position_previous, line_thickness / 2.0, draw_color)
            rl.draw_circle_v(mouse_position, line_thickness / 2.0, draw_color)
            rl.draw_line_ex(mouse_position_previous, mouse_position, line_thickness, draw_color)
            rl.end_texture_mode()

        line_thickness += rl.get_mouse_wheel_move()
        line_thickness = rm.clamp(line_thickness, 1.0, 500.0)
        mouse_position_previous = rl.get_mouse_position()

        rl.begin_drawing()
        rl.draw_texture_rec(
            canvas.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-canvas.texture.width, height = -float<-canvas.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )

        if not left_button_down:
            let preview_color = rl.Color(r = ubyte<-127, g = ubyte<-127, b = ubyte<-127, a = ubyte<-127)
            rl.draw_circle_lines_v(rl.get_mouse_position(), line_thickness / 2.0, preview_color)

        if start_text:
            rl.draw_text("try clicking and dragging!", 275, 215, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
