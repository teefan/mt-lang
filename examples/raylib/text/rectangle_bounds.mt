import examples.raylib.text.boxed_text as boxed
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function clamp_float(value: float, minimum: float, maximum: float) -> float:
    if value < minimum:
        return minimum
    if value > maximum:
        return maximum
    return value


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - rectangle bounds")
    defer rl.close_window()

    let body_text = "Text cannot escape\tthis container\t...word wrap also works when active so here's a long text for testing.\n\nLorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Nec ullamcorper sit amet risus nullam eget felis eget."

    var resizing = false
    var word_wrap = true
    var container = rl.Rectangle(x = 25.0, y = 25.0, width = float<-SCREEN_WIDTH - 50.0, height = float<-SCREEN_HEIGHT - 250.0)
    var resizer = rl.Rectangle(x = container.x + container.width - 17.0, y = container.y + container.height - 17.0, width = 14.0, height = 14.0)

    let min_width = 60.0
    let min_height = 60.0
    let max_width = float<-SCREEN_WIDTH - 50.0
    let max_height = float<-SCREEN_HEIGHT - 160.0

    var last_mouse = rl.Vector2(x = 0.0, y = 0.0)
    var border_color = rl.MAROON
    let font = rl.get_font_default()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            word_wrap = not word_wrap

        let mouse = rl.get_mouse_position()

        if rl.check_collision_point_rec(mouse, container):
            border_color = rl.fade(rl.MAROON, 0.4)
        else if not resizing:
            border_color = rl.MAROON

        if resizing:
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                resizing = false

            container.width = clamp_float(container.width + (mouse.x - last_mouse.x), min_width, max_width)
            container.height = clamp_float(container.height + (mouse.y - last_mouse.y), min_height, max_height)
        else if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) and rl.check_collision_point_rec(mouse, resizer):
            resizing = true

        resizer.x = container.x + container.width - 17.0
        resizer.y = container.y + container.height - 17.0
        last_mouse = mouse

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle_lines_ex(container, 3.0, border_color)
        boxed.draw_text_boxed(font, body_text, rl.Rectangle(x = container.x + 4.0, y = container.y + 4.0, width = container.width - 4.0, height = container.height - 4.0), 20.0, 2.0, word_wrap, rl.GRAY)
        rl.draw_rectangle_rec(resizer, border_color)

        rl.draw_rectangle(0, SCREEN_HEIGHT - 54, SCREEN_WIDTH, 54, rl.GRAY)
        rl.draw_rectangle_rec(rl.Rectangle(x = 382.0, y = float<-SCREEN_HEIGHT - 34.0, width = 12.0, height = 12.0), rl.MAROON)
        rl.draw_text("Word Wrap: ", 313, SCREEN_HEIGHT - 115, 20, rl.BLACK)
        if word_wrap:
            rl.draw_text("ON", 447, SCREEN_HEIGHT - 115, 20, rl.RED)
        else:
            rl.draw_text("OFF", 447, SCREEN_HEIGHT - 115, 20, rl.BLACK)
        rl.draw_text("Press [SPACE] to toggle word wrap", 218, SCREEN_HEIGHT - 86, 20, rl.GRAY)
        rl.draw_text("Click hold & drag the    to resize the container", 155, SCREEN_HEIGHT - 38, 20, rl.RAYWHITE)

        rl.end_drawing()

    return 0
