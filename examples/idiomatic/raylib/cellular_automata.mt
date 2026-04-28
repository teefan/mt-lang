module examples.idiomatic.raylib.cellular_automata

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const image_width: i32 = 800
const image_height: i32 = 800 / 2
const draw_rule_start_x: i32 = 585
const draw_rule_start_y: i32 = 10
const draw_rule_spacing: i32 = 15
const draw_rule_group_spacing: i32 = 50
const draw_rule_size: i32 = 14
const draw_rule_inner_size: i32 = 10
const presets_size_x: i32 = 42
const presets_size_y: i32 = 22
const lines_updated_per_frame: i32 = 4
const presets_count: i32 = 10

def compute_line(image: rl.Image, line: i32, rule: i32) -> rl.Image:
    var next_image = image
    for index in range(1, image_width - 1):
        let prev_value = (
            if rl.get_image_color(next_image, index - 1, line - 1).r < 5 then 4 else 0
        ) + (
            if rl.get_image_color(next_image, index, line - 1).r < 5 then 2 else 0
        ) + (
            if rl.get_image_color(next_image, index + 1, line - 1).r < 5 then 1 else 0
        )
        let curr_value = (rule & (1 << prev_value)) != 0
        rl.image_draw_pixel(inout next_image, index, line, if curr_value then rl.BLACK else rl.RAYWHITE)
    return next_image

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Cellular Automata")
    defer rl.close_window()

    var image = rl.gen_image_color(image_width, image_height, rl.RAYWHITE)
    rl.image_draw_pixel(inout image, image_width / 2, 0, rl.BLACK)

    let texture = rl.load_texture_from_image(image)
    defer:
        rl.unload_texture(texture)
        rl.unload_image(image)

    let preset_values = array[i32, 10](18, 30, 60, 86, 102, 124, 126, 150, 182, 225)
    var rule = 30
    var line = 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()
        var mouse_in_cell = -1

        for index in range(0, 8):
            let cell_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing
            let cell_y = draw_rule_start_y + draw_rule_spacing
            if mouse.x >= cast[f32](cell_x) and mouse.x <= cast[f32](cell_x + draw_rule_size) and mouse.y >= cast[f32](cell_y) and mouse.y <= cast[f32](cell_y + draw_rule_size):
                mouse_in_cell = index
                break

        if mouse_in_cell < 0:
            for index in range(0, presets_count):
                let cell_x = 4 + (presets_size_x + 2) * (index / 2)
                let cell_y = 2 + (presets_size_y + 2) * (index % 2)
                if mouse.x >= cast[f32](cell_x) and mouse.x <= cast[f32](cell_x + presets_size_x) and mouse.y >= cast[f32](cell_y) and mouse.y <= cast[f32](cell_y + presets_size_y):
                    mouse_in_cell = index + 8
                    break

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_in_cell >= 0:
            if mouse_in_cell < 8:
                rule = rule ^ (1 << mouse_in_cell)
            else:
                rule = preset_values[mouse_in_cell - 8]

            rl.image_clear_background(inout image, rl.RAYWHITE)
            rl.image_draw_pixel(inout image, image_width / 2, 0, rl.BLACK)
            line = 1

        if line < image_height:
            for index in range(0, lines_updated_per_frame):
                if line + index >= image_height:
                    break
                image = compute_line(image, line + index, rule)
            line += lines_updated_per_frame

            rl.update_texture_from_image(texture, image)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(texture, 0, screen_height - image_height, rl.WHITE)

        for index in range(0, presets_count):
            let preset_x = 4 + (presets_size_x + 2) * (index / 2)
            let preset_y = 2 + (presets_size_y + 2) * (index % 2)
            rl.draw_text(rl.text_format_i32("%i", preset_values[index]), 8 + (presets_size_x + 2) * (index / 2), 4 + (presets_size_y + 2) * (index % 2), 20, rl.GRAY)
            rl.draw_rectangle_lines(preset_x, preset_y, presets_size_x, presets_size_y, rl.BLUE)

            if mouse_in_cell == index + 8:
                rl.draw_rectangle_lines_ex(
                    rl.Rectangle(x = cast[f32](preset_x - 2), y = cast[f32](preset_y - 2), width = cast[f32](presets_size_x + 4), height = cast[f32](presets_size_y + 4)),
                    3.0,
                    rl.RED,
                )

        for index in range(0, 8):
            for bit_index in range(0, 3):
                let rule_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing * bit_index
                rl.draw_rectangle_lines(rule_x, draw_rule_start_y, draw_rule_size, draw_rule_size, rl.GRAY)
                if (index & (4 >> bit_index)) != 0:
                    rl.draw_rectangle(rule_x + 2, draw_rule_start_y + 2, draw_rule_inner_size, draw_rule_inner_size, rl.BLACK)

            let output_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing
            let output_y = draw_rule_start_y + draw_rule_spacing
            rl.draw_rectangle_lines(output_x, output_y, draw_rule_size, draw_rule_size, rl.BLUE)
            if (rule & (1 << index)) != 0:
                rl.draw_rectangle(output_x + 2, output_y + 2, draw_rule_inner_size, draw_rule_inner_size, rl.BLACK)

            if mouse_in_cell == index:
                rl.draw_rectangle_lines_ex(
                    rl.Rectangle(x = cast[f32](output_x - 2), y = cast[f32](output_y - 2), width = cast[f32](draw_rule_size + 4), height = cast[f32](draw_rule_size + 4)),
                    3.0,
                    rl.RED,
                )

        rl.draw_text(rl.text_format_i32("RULE: %i", rule), draw_rule_start_x + draw_rule_spacing * 4, draw_rule_start_y + 1, 30, rl.GRAY)

    return 0
