import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const IMAGE_WIDTH: int = 800
const IMAGE_HEIGHT: int = 800 / 2
const DRAW_RULE_START_X: int = 585
const DRAW_RULE_START_Y: int = 10
const DRAW_RULE_SPACING: int = 15
const DRAW_RULE_GROUP_SPACING: int = 50
const DRAW_RULE_SIZE: int = 14
const DRAW_RULE_INNER_SIZE: int = 10
const PRESETS_SIZE_X: int = 42
const PRESETS_SIZE_Y: int = 22
const LINES_UPDATED_PER_FRAME: int = 4
const PRESETS_COUNT: int = 10


function compute_line(image: ref[rl.Image], line: int, rule: int) -> void:
    var x = 1
    while x < IMAGE_WIDTH - 1:
        let left = if rl.get_image_color(read(image), x - 1, line - 1).r < 5: 4 else: 0
        let centre = if rl.get_image_color(read(image), x, line - 1).r < 5: 2 else: 0
        let right = if rl.get_image_color(read(image), x + 1, line - 1).r < 5: 1 else: 0
        let prev_value = left + centre + right
        let curr_value = (rule & (1 << prev_value)) != 0
        rl.image_draw_pixel(read(image), x, line, if curr_value: rl.BLACK else: rl.RAYWHITE)
        x += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - cellular automata")
    defer rl.close_window()

    var image = rl.gen_image_color(IMAGE_WIDTH, IMAGE_HEIGHT, rl.RAYWHITE)
    defer rl.unload_image(image)
    rl.image_draw_pixel(image, IMAGE_WIDTH / 2, 0, rl.BLACK)

    let texture = rl.load_texture_from_image(image)
    defer rl.unload_texture(texture)

    let preset_values = array[int, PRESETS_COUNT](18, 30, 60, 86, 102, 124, 126, 150, 182, 225)

    var rule = 30
    var line = 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()
        var mouse_in_cell = -1

        var index = 0
        while index < 8:
            let cell_x = DRAW_RULE_START_X - DRAW_RULE_GROUP_SPACING * index + DRAW_RULE_SPACING
            let cell_y = DRAW_RULE_START_Y + DRAW_RULE_SPACING
            if mouse.x >= float<-cell_x and mouse.x <= float<-(cell_x + DRAW_RULE_SIZE) and
               mouse.y >= float<-cell_y and mouse.y <= float<-(cell_y + DRAW_RULE_SIZE):
                mouse_in_cell = index
                break
            index += 1

        if mouse_in_cell < 0:
            index = 0
            while index < PRESETS_COUNT:
                let cell_x = 4 + (PRESETS_SIZE_X + 2) * (index / 2)
                let cell_y = 2 + (PRESETS_SIZE_Y + 2) * (index % 2)
                if mouse.x >= float<-cell_x and mouse.x <= float<-(cell_x + PRESETS_SIZE_X) and
                   mouse.y >= float<-cell_y and mouse.y <= float<-(cell_y + PRESETS_SIZE_Y):
                    mouse_in_cell = index + 8
                    break
                index += 1

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and mouse_in_cell >= 0:
            if mouse_in_cell < 8:
                let mask = 1 << mouse_in_cell
                rule = if (rule & mask) != 0: rule - mask else: rule + mask
            else:
                rule = preset_values[mouse_in_cell - 8]

            rl.image_clear_background(image, rl.RAYWHITE)
            rl.image_draw_pixel(image, IMAGE_WIDTH / 2, 0, rl.BLACK)
            line = 1

        if line < IMAGE_HEIGHT:
            index = 0
            while index < LINES_UPDATED_PER_FRAME and line + index < IMAGE_HEIGHT:
                compute_line(ref_of(image), line + index, rule)
                index += 1
            line += LINES_UPDATED_PER_FRAME

            rl.update_texture(texture, unsafe: ptr[rl.Color]<-image.data)

        let rule_text = rl.text_format("RULE: %i", rule)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(texture, 0, SCREEN_HEIGHT - IMAGE_HEIGHT, rl.WHITE)

        index = 0
        while index < PRESETS_COUNT:
            let preset_x = 4 + (PRESETS_SIZE_X + 2) * (index / 2)
            let preset_y = 2 + (PRESETS_SIZE_Y + 2) * (index % 2)
            let preset_text = rl.text_format("%i", preset_values[index])
            rl.draw_text(preset_text, preset_x + 4, preset_y + 2, 20, rl.GRAY)
            rl.draw_rectangle_lines(preset_x, preset_y, PRESETS_SIZE_X, PRESETS_SIZE_Y, rl.BLUE)

            if mouse_in_cell == index + 8:
                rl.draw_rectangle_lines_ex(
                    rl.Rectangle(
                        x = float<-(preset_x - 2),
                        y = float<-preset_y,
                        width = float<-(PRESETS_SIZE_X + 4),
                        height = float<-(PRESETS_SIZE_Y + 4),
                    ),
                    3.0,
                    rl.RED,
                )
            index += 1

        index = 0
        while index < 8:
            var bit = 0
            while bit < 3:
                let bit_x = DRAW_RULE_START_X - DRAW_RULE_GROUP_SPACING * index + DRAW_RULE_SPACING * bit
                rl.draw_rectangle_lines(bit_x, DRAW_RULE_START_Y, DRAW_RULE_SIZE, DRAW_RULE_SIZE, rl.GRAY)
                if (index & (4 >> bit)) != 0:
                    rl.draw_rectangle(bit_x + 2, DRAW_RULE_START_Y + 2, DRAW_RULE_INNER_SIZE, DRAW_RULE_INNER_SIZE, rl.BLACK)
                bit += 1

            let output_x = DRAW_RULE_START_X - DRAW_RULE_GROUP_SPACING * index + DRAW_RULE_SPACING
            rl.draw_rectangle_lines(output_x, DRAW_RULE_START_Y + DRAW_RULE_SPACING, DRAW_RULE_SIZE, DRAW_RULE_SIZE, rl.BLUE)
            if (rule & (1 << index)) != 0:
                rl.draw_rectangle(output_x + 2, DRAW_RULE_START_Y + DRAW_RULE_SPACING + 2, DRAW_RULE_INNER_SIZE, DRAW_RULE_INNER_SIZE, rl.BLACK)

            if mouse_in_cell == index:
                rl.draw_rectangle_lines_ex(
                    rl.Rectangle(
                        x = float<-(output_x - 2),
                        y = float<-(DRAW_RULE_START_Y + DRAW_RULE_SPACING - 2),
                        width = float<-(DRAW_RULE_SIZE + 4),
                        height = float<-(DRAW_RULE_SIZE + 4),
                    ),
                    3.0,
                    rl.RED,
                )
            index += 1

        rl.draw_text(rule_text, DRAW_RULE_START_X + DRAW_RULE_SPACING * 4, DRAW_RULE_START_Y + 1, 30, rl.GRAY)
        rl.end_drawing()

    return 0
