import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_COLORS_COUNT: int = 23


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - mouse painting")
    defer rl.close_window()

    let colors = array[rl.Color, MAX_COLORS_COUNT](
        rl.RAYWHITE,
        rl.YELLOW,
        rl.GOLD,
        rl.ORANGE,
        rl.PINK,
        rl.RED,
        rl.MAROON,
        rl.GREEN,
        rl.LIME,
        rl.DARKGREEN,
        rl.SKYBLUE,
        rl.BLUE,
        rl.DARKBLUE,
        rl.PURPLE,
        rl.VIOLET,
        rl.DARKPURPLE,
        rl.BEIGE,
        rl.BROWN,
        rl.DARKBROWN,
        rl.LIGHTGRAY,
        rl.GRAY,
        rl.DARKGRAY,
        rl.BLACK
    )

    var color_rects: array[rl.Rectangle, MAX_COLORS_COUNT] = zero[array[rl.Rectangle, MAX_COLORS_COUNT]]
    var index = 0
    while index < MAX_COLORS_COUNT:
        color_rects[index].x = 10.0 + 30.0 * float<-index + 2.0 * float<-index
        color_rects[index].y = 10.0
        color_rects[index].width = 30.0
        color_rects[index].height = 30.0
        index += 1

    var color_selected = 0
    var color_selected_prev = 0
    var color_mouse_hover = -1
    var brush_size = float<-20.0
    var mouse_was_pressed = false

    let save_button = rl.Rectangle(x = 750.0, y = 10.0, width = 40.0, height = 30.0)
    var save_button_hover = false
    var show_save_message = false
    var save_message_counter = 0

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)

    rl.begin_texture_mode(target)
    rl.clear_background(colors[0])
    rl.end_texture_mode()

    rl.set_target_fps(120)

    while not rl.window_should_close():
        let mouse_pos = rl.get_mouse_position()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            color_selected += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            color_selected -= 1

        if color_selected >= MAX_COLORS_COUNT:
            color_selected = MAX_COLORS_COUNT - 1
        else if color_selected < 0:
            color_selected = 0

        color_mouse_hover = -1
        index = 0
        while index < MAX_COLORS_COUNT:
            if rl.check_collision_point_rec(mouse_pos, color_rects[index]):
                color_mouse_hover = index
                break
            index += 1

        if color_mouse_hover >= 0 and rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            color_selected = color_mouse_hover
            color_selected_prev = color_selected

        brush_size += rl.get_mouse_wheel_move() * 5.0
        if brush_size < 2.0:
            brush_size = 2.0
        else if brush_size > 50.0:
            brush_size = 50.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            rl.begin_texture_mode(target)
            rl.clear_background(colors[0])
            rl.end_texture_mode()

        if (
            rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT)
            or rl.get_gesture_detected() == int<-rl.Gesture.GESTURE_DRAG
        ):
            rl.begin_texture_mode(target)
            if mouse_pos.y > 50.0:
                rl.draw_circle(int<-mouse_pos.x, int<-mouse_pos.y, brush_size, colors[color_selected])
            rl.end_texture_mode()

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if not mouse_was_pressed:
                color_selected_prev = color_selected
                color_selected = 0

            mouse_was_pressed = true

            rl.begin_texture_mode(target)
            if mouse_pos.y > 50.0:
                rl.draw_circle(int<-mouse_pos.x, int<-mouse_pos.y, brush_size, colors[0])
            rl.end_texture_mode()
        else if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_RIGHT) and mouse_was_pressed:
            color_selected = color_selected_prev
            mouse_was_pressed = false

        save_button_hover = rl.check_collision_point_rec(mouse_pos, save_button)

        if (save_button_hover and rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT)) or rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            var image = rl.load_image_from_texture(target.texture)
            rl.image_flip_vertical(image)
            rl.export_image(image, "my_amazing_texture_painting.png")
            rl.unload_image(image)
            show_save_message = true

        if show_save_message:
            save_message_counter += 1
            if save_message_counter > 240:
                show_save_message = false
                save_message_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -float<-target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )

        if mouse_pos.y > 50.0:
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                rl.draw_circle_lines(int<-mouse_pos.x, int<-mouse_pos.y, brush_size, rl.GRAY)
            else:
                rl.draw_circle(int<-mouse_pos.x, int<-mouse_pos.y, brush_size, colors[color_selected])

        rl.draw_rectangle(0, 0, rl.get_screen_width(), 50, rl.RAYWHITE)
        rl.draw_line(0, 50, rl.get_screen_width(), 50, rl.LIGHTGRAY)

        index = 0
        while index < MAX_COLORS_COUNT:
            rl.draw_rectangle_rec(color_rects[index], colors[index])
            index += 1
        rl.draw_rectangle_lines(10, 10, 30, 30, rl.LIGHTGRAY)

        if color_mouse_hover >= 0:
            rl.draw_rectangle_rec(color_rects[color_mouse_hover], rl.fade(rl.WHITE, 0.6))

        rl.draw_rectangle_lines_ex(
            rl.Rectangle(
                x = color_rects[color_selected].x - 2.0,
                y = color_rects[color_selected].y - 2.0,
                width = color_rects[color_selected].width + 4.0,
                height = color_rects[color_selected].height + 4.0
            ),
            2.0,
            rl.BLACK
        )

        let save_button_color = if save_button_hover: rl.RED else: rl.BLACK
        rl.draw_rectangle_lines_ex(save_button, 2.0, save_button_color)
        rl.draw_text("SAVE!", 755, 20, 10, save_button_color)

        if show_save_message:
            rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.fade(rl.RAYWHITE, 0.8))
            rl.draw_rectangle(0, 150, rl.get_screen_width(), 80, rl.BLACK)
            rl.draw_text("IMAGE SAVED!", 150, 180, 20, rl.RAYWHITE)

        rl.end_drawing()

    return 0
