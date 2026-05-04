module examples.raylib.textures.textures_cellular_automata

import std.c.raylib as rl

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
const window_title: cstr = c"raylib [textures] example - cellular automata"


def compute_line(image: ref[rl.Image], line: i32, rule: i32) -> void:
    for index in 1..image_width - 1:
        let prev_value = (
            if rl.GetImageColor(read(image), index - 1, line - 1).r < 5: 4 else: 0
        ) + (
            if rl.GetImageColor(read(image), index, line - 1).r < 5: 2 else: 0
        ) + (
            if rl.GetImageColor(read(image), index + 1, line - 1).r < 5: 1 else: 0
        )
        let curr_value = (rule & (1 << prev_value)) != 0
        rl.ImageDrawPixel(ptr_of(image), index, line, if curr_value: rl.BLACK else: rl.RAYWHITE)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var image = rl.GenImageColor(image_width, image_height, rl.RAYWHITE)
    rl.ImageDrawPixel(ptr_of(image), image_width / 2, 0, rl.BLACK)

    let texture = rl.LoadTextureFromImage(image)
    defer:
        rl.UnloadTexture(texture)
        rl.UnloadImage(image)

    let preset_values = array[i32, 10](18, 30, 60, 86, 102, 124, 126, 150, 182, 225)
    var rule = 30
    var line = 1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse = rl.GetMousePosition()
        var mouse_in_cell = -1

        for index in 0..8:
            let cell_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing
            let cell_y = draw_rule_start_y + draw_rule_spacing
            if mouse.x >= f32<-cell_x and mouse.x <= f32<-(cell_x + draw_rule_size) and mouse.y >= f32<-cell_y and mouse.y <= f32<-(cell_y + draw_rule_size):
                mouse_in_cell = index
                break

        if mouse_in_cell < 0:
            for index in 0..presets_count:
                let cell_x = 4 + (presets_size_x + 2) * (index / 2)
                let cell_y = 2 + (presets_size_y + 2) * (index % 2)
                if mouse.x >= f32<-cell_x and mouse.x <= f32<-(cell_x + presets_size_x) and mouse.y >= f32<-cell_y and mouse.y <= f32<-(cell_y + presets_size_y):
                    mouse_in_cell = index + 8
                    break

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_in_cell >= 0:
            if mouse_in_cell < 8:
                rule ^= 1 << mouse_in_cell
            else:
                rule = preset_values[mouse_in_cell - 8]

            rl.ImageClearBackground(ptr_of(image), rl.RAYWHITE)
            rl.ImageDrawPixel(ptr_of(image), image_width / 2, 0, rl.BLACK)
            line = 1

        if line < image_height:
            for index in 0..lines_updated_per_frame:
                if line + index >= image_height:
                    break
                compute_line(ref_of(image), line + index, rule)
            line += lines_updated_per_frame

            rl.UpdateTexture(texture, image.data)

        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawTexture(texture, 0, screen_height - image_height, rl.WHITE)

        for index in 0..presets_count:
            let preset_x = 4 + (presets_size_x + 2) * (index / 2)
            let preset_y = 2 + (presets_size_y + 2) * (index % 2)
            rl.DrawText(rl.TextFormat(c"%i", preset_values[index]), 8 + (presets_size_x + 2) * (index / 2), 4 + (presets_size_y + 2) * (index % 2), 20, rl.GRAY)
            rl.DrawRectangleLines(preset_x, preset_y, presets_size_x, presets_size_y, rl.BLUE)

            if mouse_in_cell == index + 8:
                rl.DrawRectangleLinesEx(
                    rl.Rectangle(x = f32<-(preset_x - 2), y = f32<-(preset_y - 2), width = f32<-(presets_size_x + 4), height = f32<-(presets_size_y + 4)),
                    3.0,
                    rl.RED,
                )

        for index in 0..8:
            for bit_index in 0..3:
                let rule_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing * bit_index
                rl.DrawRectangleLines(rule_x, draw_rule_start_y, draw_rule_size, draw_rule_size, rl.GRAY)
                if (index & (4 >> bit_index)) != 0:
                    rl.DrawRectangle(rule_x + 2, draw_rule_start_y + 2, draw_rule_inner_size, draw_rule_inner_size, rl.BLACK)

            let output_x = draw_rule_start_x - draw_rule_group_spacing * index + draw_rule_spacing
            let output_y = draw_rule_start_y + draw_rule_spacing
            rl.DrawRectangleLines(output_x, output_y, draw_rule_size, draw_rule_size, rl.BLUE)
            if (rule & (1 << index)) != 0:
                rl.DrawRectangle(output_x + 2, output_y + 2, draw_rule_inner_size, draw_rule_inner_size, rl.BLACK)

            if mouse_in_cell == index:
                rl.DrawRectangleLinesEx(
                    rl.Rectangle(x = f32<-(output_x - 2), y = f32<-(output_y - 2), width = f32<-(draw_rule_size + 4), height = f32<-(draw_rule_size + 4)),
                    3.0,
                    rl.RED,
                )

        rl.DrawText(rl.TextFormat(c"RULE: %i", rule), draw_rule_start_x + draw_rule_spacing * 4, draw_rule_start_y + 1, 30, rl.GRAY)

        rl.EndDrawing()

    return 0
