module examples.idiomatic.raylib.mouse_painting

import std.raylib as rl

const max_colors_count: i32 = 23
const screen_width: i32 = 800
const screen_height: i32 = 450
const save_path: str = "my_amazing_texture_painting.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Mouse Painting")
    defer rl.close_window()

    let colors = array[rl.Color, 23](
        rl.RAYWHITE, rl.YELLOW, rl.GOLD, rl.ORANGE, rl.PINK, rl.RED, rl.MAROON, rl.GREEN, rl.LIME, rl.DARKGREEN,
        rl.SKYBLUE, rl.BLUE, rl.DARKBLUE, rl.PURPLE, rl.VIOLET, rl.DARKPURPLE, rl.BEIGE, rl.BROWN, rl.DARKBROWN,
        rl.LIGHTGRAY, rl.GRAY, rl.DARKGRAY, rl.BLACK,
    )

    var colors_recs = zero[array[rl.Rectangle, 23]]()
    for index in range(0, max_colors_count):
        colors_recs[index].x = 10.0 + 30.0 * cast[f32](index) + 2.0 * cast[f32](index)
        colors_recs[index].y = 10.0
        colors_recs[index].width = 30.0
        colors_recs[index].height = 30.0

    var color_selected = 0
    var color_selected_prev = color_selected
    var color_mouse_hover = 0
    var brush_size: f32 = 20.0
    var mouse_was_pressed = false

    let btn_save_rec = rl.Rectangle(x = 750.0, y = 10.0, width = 40.0, height = 30.0)
    var btn_save_mouse_hover = false
    var show_save_message = false
    var save_message_counter = 0

    let target = rl.load_render_texture(screen_width, screen_height)
    defer rl.unload_render_texture(target)

    rl.begin_texture_mode(target)
    rl.clear_background(colors[0])
    rl.end_texture_mode()

    rl.set_target_fps(120)

    while not rl.window_should_close():
        let mouse_pos = rl.get_mouse_position()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            color_selected += 1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            color_selected -= 1

        if color_selected >= max_colors_count:
            color_selected = max_colors_count - 1
        elif color_selected < 0:
            color_selected = 0

        color_mouse_hover = -1
        for index in range(0, max_colors_count):
            if rl.check_collision_point_rec(mouse_pos, colors_recs[index]):
                color_mouse_hover = index
                break

        if color_mouse_hover >= 0 and rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            color_selected = color_mouse_hover
            color_selected_prev = color_selected

        brush_size += rl.get_mouse_wheel_move() * 5.0
        if brush_size < 2.0:
            brush_size = 2.0
        if brush_size > 50.0:
            brush_size = 50.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            rl.begin_texture_mode(target)
            rl.clear_background(colors[0])
            rl.end_texture_mode()

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.get_gesture_detected() == rl.Gesture.GESTURE_DRAG:
            rl.begin_texture_mode(target)
            if mouse_pos.y > 50.0:
                rl.draw_circle(cast[i32](mouse_pos.x), cast[i32](mouse_pos.y), brush_size, colors[color_selected])
            rl.end_texture_mode()

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if not mouse_was_pressed:
                color_selected_prev = color_selected
                color_selected = 0

            mouse_was_pressed = true

            rl.begin_texture_mode(target)
            if mouse_pos.y > 50.0:
                rl.draw_circle(cast[i32](mouse_pos.x), cast[i32](mouse_pos.y), brush_size, colors[0])
            rl.end_texture_mode()
        elif rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_RIGHT) and mouse_was_pressed:
            color_selected = color_selected_prev
            mouse_was_pressed = false

        btn_save_mouse_hover = rl.check_collision_point_rec(mouse_pos, btn_save_rec)

        if (btn_save_mouse_hover and rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT)) or rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            var image = rl.load_image_from_texture(target.texture)
            rl.image_flip_vertical(inout image)
            rl.export_image(image, save_path)
            rl.unload_image(image)
            show_save_message = true

        if show_save_message:
            save_message_counter += 1
            if save_message_counter > 240:
                show_save_message = false
                save_message_counter = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = cast[f32](target.texture.width), height = -cast[f32](target.texture.height)),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )

        if mouse_pos.y > 50.0:
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
                rl.draw_circle_lines(cast[i32](mouse_pos.x), cast[i32](mouse_pos.y), brush_size, rl.GRAY)
            else:
                rl.draw_circle(rl.get_mouse_x(), rl.get_mouse_y(), brush_size, colors[color_selected])

        rl.draw_rectangle(0, 0, rl.get_screen_width(), 50, rl.RAYWHITE)
        rl.draw_line(0, 50, rl.get_screen_width(), 50, rl.LIGHTGRAY)

        for index in range(0, max_colors_count):
            rl.draw_rectangle_rec(colors_recs[index], colors[index])
        rl.draw_rectangle_lines(10, 10, 30, 30, rl.LIGHTGRAY)

        if color_mouse_hover >= 0:
            rl.draw_rectangle_rec(colors_recs[color_mouse_hover], rl.fade(rl.WHITE, 0.6))

        rl.draw_rectangle_lines_ex(
            rl.Rectangle(
                x = colors_recs[color_selected].x - 2.0,
                y = colors_recs[color_selected].y - 2.0,
                width = colors_recs[color_selected].width + 4.0,
                height = colors_recs[color_selected].height + 4.0,
            ),
            2.0,
            rl.BLACK,
        )

        rl.draw_rectangle_lines_ex(btn_save_rec, 2.0, if btn_save_mouse_hover then rl.RED else rl.BLACK)
        rl.draw_text("SAVE!", 755, 20, 10, if btn_save_mouse_hover then rl.RED else rl.BLACK)

        if show_save_message:
            rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.fade(rl.RAYWHITE, 0.8))
            rl.draw_rectangle(0, 150, rl.get_screen_width(), 80, rl.BLACK)
            rl.draw_text("IMAGE SAVED!", 150, 180, 20, rl.RAYWHITE)

    return 0
