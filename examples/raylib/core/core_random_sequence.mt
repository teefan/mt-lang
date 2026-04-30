module examples.raylib.core.core_random_sequence

import std.c.raylib as rl
import std.mem.heap as heap

struct ColorRect:
    color: rl.Color
    rect: rl.Rectangle

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - random sequence"
const initial_rect_count: i32 = 20
const sequence_height_factor: f32 = 0.75
const min_rect_count: i32 = 4

def remap(value: f32, input_start: f32, input_end: f32, output_start: f32, output_end: f32) -> f32:
    if input_end == input_start:
        return output_start
    let normalized = (value - input_start) / (input_end - input_start)
    return output_start + normalized * (output_end - output_start)

def generate_random_color() -> rl.Color:
    return rl.Color(
        r = rl.GetRandomValue(0, 255),
        g = rl.GetRandomValue(0, 255),
        b = rl.GetRandomValue(0, 255),
        a = 255,
    )

def alloc_color_rects(rect_count: i32) -> ptr[ColorRect]:
    return heap.must_alloc_zeroed[ColorRect](usize<-rect_count)

def release_color_rects(rectangles: ptr[ColorRect]) -> void:
    heap.release(rectangles)
    return

def generate_random_color_rect_sequence(rect_count: i32, rect_width: f32, width: f32, height: f32) -> ptr[ColorRect]:
    let rectangles = alloc_color_rects(rect_count)
    let sequence = rl.LoadRandomSequence(rect_count, 0, rect_count - 1)
    var rectangles_view = span[ColorRect](data = rectangles, len = usize<-rect_count)
    let sequence_view = span[i32](data = sequence, len = usize<-rect_count)
    let rect_sequence_width = rect_count * rect_width
    let start_x = (width - rect_sequence_width) * 0.5

    var index = 0
    while index < rect_count:
        let rect_height = i32<-remap(f32<-sequence_view[index], 0.0, f32<-(rect_count - 1), 0.0, height)
        rectangles_view[index].color = generate_random_color()
        rectangles_view[index].rect = rl.Rectangle(
            x = start_x + index * rect_width,
            y = height - rect_height,
            width = rect_width,
            height = rect_height,
        )
        index += 1

    rl.UnloadRandomSequence(sequence)
    return rectangles

def swap_color_rect_values(left: ref[ColorRect], right: ref[ColorRect]) -> void:
    let tmp = read(left)
    left.color = right.color
    left.rect.height = right.rect.height
    left.rect.y = right.rect.y
    right.color = tmp.color
    right.rect.height = tmp.rect.height
    right.rect.y = tmp.rect.y
    return

def shuffle_color_rect_sequence(rectangles: ptr[ColorRect], rect_count: i32) -> void:
    let sequence = rl.LoadRandomSequence(rect_count, 0, rect_count - 1)
    var rectangles_view = span[ColorRect](data = rectangles, len = usize<-rect_count)
    let sequence_view = span[i32](data = sequence, len = usize<-rect_count)

    var index = 0
    while index < rect_count:
        let right_index = sequence_view[index]
        swap_color_rect_values(ref_of(rectangles_view[index]), ref_of(rectangles_view[right_index]))
        index += 1

    rl.UnloadRandomSequence(sequence)
    return

def draw_help_text(height: i32) -> void:
    rl.DrawText(c"Press SPACE to shuffle the current sequence", 10, height - 96, 20, rl.BLACK)
    rl.DrawText(c"Press UP to add a rectangle and generate a new sequence", 10, height - 64, 20, rl.BLACK)
    rl.DrawText(c"Press DOWN to remove a rectangle and generate a new sequence", 10, height - 32, 20, rl.BLACK)

def rect_count_text(rect_count: i32) -> cstr:
    if rect_count == 4:
        return c"Count: 4 rectangles"
    if rect_count == 5:
        return c"Count: 5 rectangles"
    if rect_count == 6:
        return c"Count: 6 rectangles"
    if rect_count == 7:
        return c"Count: 7 rectangles"
    if rect_count == 8:
        return c"Count: 8 rectangles"
    if rect_count == 9:
        return c"Count: 9 rectangles"
    if rect_count == 10:
        return c"Count: 10 rectangles"
    if rect_count == 11:
        return c"Count: 11 rectangles"
    if rect_count == 12:
        return c"Count: 12 rectangles"
    if rect_count == 13:
        return c"Count: 13 rectangles"
    if rect_count == 14:
        return c"Count: 14 rectangles"
    if rect_count == 15:
        return c"Count: 15 rectangles"
    if rect_count == 16:
        return c"Count: 16 rectangles"
    if rect_count == 17:
        return c"Count: 17 rectangles"
    if rect_count == 18:
        return c"Count: 18 rectangles"
    if rect_count == 19:
        return c"Count: 19 rectangles"
    if rect_count == 20:
        return c"Count: 20 rectangles"
    if rect_count == 21:
        return c"Count: 21 rectangles"
    return c"Count: 22 rectangles"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var rect_count = initial_rect_count
    var rect_size = f32<-screen_width / f32<-rect_count
    var rectangles = generate_random_color_rect_sequence(
        rect_count,
        rect_size,
        f32<-screen_width,
        sequence_height_factor * f32<-screen_height,
    )
    defer release_color_rects(rectangles)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            shuffle_color_rect_sequence(rectangles, rect_count)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            rect_count += 1
            rect_size = f32<-screen_width / f32<-rect_count
            release_color_rects(rectangles)
            rectangles = generate_random_color_rect_sequence(
                rect_count,
                rect_size,
                f32<-screen_width,
                sequence_height_factor * f32<-screen_height,
            )

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN) and rect_count >= min_rect_count:
            rect_count -= 1
            rect_size = f32<-screen_width / f32<-rect_count
            release_color_rects(rectangles)
            rectangles = generate_random_color_rect_sequence(
                rect_count,
                rect_size,
                f32<-screen_width,
                sequence_height_factor * f32<-screen_height,
            )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        let rectangles_view = span[ColorRect](data = rectangles, len = usize<-rect_count)

        var index = 0
        while index < rect_count:
            rl.DrawRectangleRec(rectangles_view[index].rect, rectangles_view[index].color)
            index += 1

        draw_help_text(screen_height)
        rl.DrawText(rect_count_text(rect_count), 10, 10, 20, rl.MAROON)
        rl.DrawFPS(screen_width - 80, 10)

    return 0
