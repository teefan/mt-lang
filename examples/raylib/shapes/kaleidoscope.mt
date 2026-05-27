import std.raygui as gui
import std.raylib as rl
import std.raymath as math
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_DRAW_LINES: int = 8192
const DEG_TO_RAD: float = rl.PI / 180.0


struct Line:
    start: rl.Vector2
    end: rl.Vector2


var lines: array[Line, MAX_DRAW_LINES] = zero[array[Line, MAX_DRAW_LINES]]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - kaleidoscope")
    defer rl.close_window()

    let symmetry = 6
    let angle: float = 360.0 / float<-symmetry
    let thickness: float = 3.0
    let reset_button_rec = rl.Rectangle(x = float<-SCREEN_WIDTH - 55.0, y = 5.0, width = 50.0, height = 25.0)
    let back_button_rec = rl.Rectangle(x = float<-SCREEN_WIDTH - 55.0, y = float<-SCREEN_HEIGHT - 30.0, width = 25.0, height = 25.0)
    let next_button_rec = rl.Rectangle(x = float<-SCREEN_WIDTH - 30.0, y = float<-SCREEN_HEIGHT - 30.0, width = 25.0, height = 25.0)
    var mouse_pos: rl.Vector2 = zero[rl.Vector2]
    var prev_mouse_pos: rl.Vector2 = zero[rl.Vector2]
    let scale_vector = rl.Vector2(x = 1.0, y = -1.0)
    let offset = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0)

    let camera = rl.Camera2D(
        target = zero[rl.Vector2],
        offset = offset,
        rotation = 0.0,
        zoom = 1.0,
    )

    var current_line_counter = 0
    var total_line_counter = 0
    var reset_button_clicked = false
    var back_button_clicked = false
    var next_button_clicked = false

    rl.set_target_fps(20)

    while not rl.window_should_close():
        prev_mouse_pos = mouse_pos
        mouse_pos = rl.get_mouse_position()

        var line_start = math.vector2_subtract(mouse_pos, offset)
        var line_end = math.vector2_subtract(prev_mouse_pos, offset)

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) and not rl.check_collision_point_rec(mouse_pos, reset_button_rec) and not rl.check_collision_point_rec(mouse_pos, back_button_rec) and not rl.check_collision_point_rec(mouse_pos, next_button_rec):
            var symmetry_index = 0
            while symmetry_index < symmetry and total_line_counter < (MAX_DRAW_LINES - 1):
                line_start = math.vector2_rotate(line_start, angle * DEG_TO_RAD)
                line_end = math.vector2_rotate(line_end, angle * DEG_TO_RAD)

                lines[total_line_counter].start = line_start
                lines[total_line_counter].end = line_end
                lines[total_line_counter + 1].start = math.vector2_multiply(line_start, scale_vector)
                lines[total_line_counter + 1].end = math.vector2_multiply(line_end, scale_vector)

                total_line_counter += 2
                current_line_counter = total_line_counter
                symmetry_index += 1

        if reset_button_clicked:
            lines = zero[array[Line, MAX_DRAW_LINES]]
            current_line_counter = 0
            total_line_counter = 0

        if back_button_clicked and current_line_counter > 0:
            current_line_counter -= 1

        if next_button_clicked and current_line_counter < MAX_DRAW_LINES and (current_line_counter + 1) <= total_line_counter:
            current_line_counter += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_2d(camera)

        var index = 0
        while index < current_line_counter:
            rl.draw_line_ex(lines[index].start, lines[index].end, thickness, rl.BLACK)
            if index + 1 < current_line_counter:
                rl.draw_line_ex(lines[index + 1].start, lines[index + 1].end, thickness, rl.BLACK)
            index += 2

        rl.end_mode_2d()

        if current_line_counter <= 0:
            gui.disable()
        back_button_clicked = gui.button(back_button_rec, "<") != 0
        gui.enable()

        if current_line_counter >= total_line_counter:
            gui.disable()
        next_button_clicked = gui.button(next_button_rec, ">") != 0
        gui.enable()

        reset_button_clicked = gui.button(reset_button_rec, "Reset") != 0

        rl.draw_text(text.cstr_as_str(rl.text_format("LINES: %i/%i", current_line_counter, MAX_DRAW_LINES)), 10, SCREEN_HEIGHT - 30, 20, rl.MAROON)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
