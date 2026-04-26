module examples.idiomatic.raylib.random_sequence

import std.raylib as rl

struct ColorRect:
    color: rl.Color
    rect: rl.Rectangle

const screen_width: i32 = 800
const screen_height: i32 = 450
const initial_rect_count: i32 = 20
const min_rect_count: i32 = 4
const max_rect_count: i32 = 22
const sequence_height_factor: f32 = 0.75

def remap(value: f32, input_start: f32, input_end: f32, output_start: f32, output_end: f32) -> f32:
    if input_end == input_start:
        return output_start
    let normalized = (value - input_start) / (input_end - input_start)
    return output_start + normalized * (output_end - output_start)

def generate_random_color() -> rl.Color:
    return rl.Color(
        r = rl.get_random_value(0, 255),
        g = rl.get_random_value(0, 255),
        b = rl.get_random_value(0, 255),
        a = 255,
    )

def shuffled_ranks(rect_count: i32) -> array[i32, 22]:
    var ranks = zero[array[i32, 22]]()

    var index = 0
    while index < rect_count:
        ranks[index] = index
        index += 1

    index = rect_count - 1
    while index > 0:
        let swap_index = rl.get_random_value(0, index)
        let tmp = ranks[index]
        ranks[index] = ranks[swap_index]
        ranks[swap_index] = tmp
        index -= 1

    return ranks

def generate_rectangles(rect_count: i32, rect_width: f32, width: f32, height: f32) -> array[ColorRect, 22]:
    var rectangles = zero[array[ColorRect, 22]]()
    let ranks = shuffled_ranks(rect_count)
    let rect_sequence_width = cast[f32](rect_count) * rect_width
    let start_x = (width - rect_sequence_width) * 0.5

    var index = 0
    while index < rect_count:
        let rect_height = remap(cast[f32](ranks[index]), 0.0, cast[f32](rect_count - 1), 0.0, height)
        rectangles[index].color = generate_random_color()
        rectangles[index].rect = rl.Rectangle(
            x = start_x + cast[f32](index) * rect_width,
            y = height - rect_height,
            width = rect_width,
            height = rect_height,
        )
        index += 1

    return rectangles

def shuffle_rectangles(rectangles: array[ColorRect, 22], rect_count: i32) -> array[ColorRect, 22]:
    var shuffled = rectangles
    let order = shuffled_ranks(rect_count)

    var index = 0
    while index < rect_count:
        let source = rectangles[order[index]]
        shuffled[index].color = source.color
        shuffled[index].rect.y = source.rect.y
        shuffled[index].rect.height = source.rect.height
        index += 1

    return shuffled

def draw_help_text(height: i32) -> void:
    rl.draw_text("Press SPACE to shuffle the current sequence", 10, height - 96, 20, rl.BLACK)
    rl.draw_text("Press UP to add a rectangle and generate a new sequence", 10, height - 64, 20, rl.BLACK)
    rl.draw_text("Press DOWN to remove a rectangle and generate a new sequence", 10, height - 32, 20, rl.BLACK)
    return

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Random Sequence")
    defer rl.close_window()

    var rect_count = initial_rect_count
    var rect_size = cast[f32](screen_width) / cast[f32](rect_count)
    var rectangles = generate_rectangles(
        rect_count,
        rect_size,
        cast[f32](screen_width),
        sequence_height_factor * cast[f32](screen_height),
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rectangles = shuffle_rectangles(rectangles, rect_count)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) and rect_count < max_rect_count:
            rect_count += 1
            rect_size = cast[f32](screen_width) / cast[f32](rect_count)
            rectangles = generate_rectangles(
                rect_count,
                rect_size,
                cast[f32](screen_width),
                sequence_height_factor * cast[f32](screen_height),
            )

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) and rect_count > min_rect_count:
            rect_count -= 1
            rect_size = cast[f32](screen_width) / cast[f32](rect_count)
            rectangles = generate_rectangles(
                rect_count,
                rect_size,
                cast[f32](screen_width),
                sequence_height_factor * cast[f32](screen_height),
            )

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < rect_count:
            rl.draw_rectangle_rec(rectangles[index].rect, rectangles[index].color)
            index += 1

        draw_help_text(screen_height)
        rl.draw_text(rl.text_format_i32("Count: %i rectangles", rect_count), 10, 10, 20, rl.MAROON)
        rl.draw_fps(screen_width - 80, 10)

    return 0
