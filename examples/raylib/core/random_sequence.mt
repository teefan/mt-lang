import std.raylib as rl
import std.raymath as math
import std.vec as vec

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450

struct ColorRect:
    color: rl.Color
    rect: rl.Rectangle


function generate_random_color() -> rl.Color:
    return rl.Color(
        r = ubyte<-rl.get_random_value(0, 255),
        g = ubyte<-rl.get_random_value(0, 255),
        b = ubyte<-rl.get_random_value(0, 255),
        a = 255ub
    )


function generate_random_color_rect_sequence(
    rect_count: int,
    rect_width: float,
    screen_width: float,
    screen_height: float
) -> vec.Vec[ColorRect]:
    var rectangles = vec.Vec[ColorRect].with_capacity(ptr_uint<-rect_count)
    let sequence = rl.load_random_sequence(uint<-rect_count, 0, rect_count - 1) else:
        fatal("could not allocate random sequence")
    defer rl.unload_random_sequence(sequence)

    let rect_sequence_width = (float<-rect_count) * rect_width
    let start_x = (screen_width - rect_sequence_width) * 0.5

    var index = 0
    while index < rect_count:
        let mapped_value = unsafe: read(sequence + ptr_uint<-index)
        let rect_height = int<-math.remap(float<-mapped_value, 0.0, float<-(rect_count - 1), 0.0, screen_height)

        rectangles.push(ColorRect(
            color = generate_random_color(),
            rect = rl.Rectangle(
                x = start_x + (float<-index) * rect_width,
                y = screen_height - (float<-rect_height),
                width = rect_width,
                height = float<-rect_height
            )
        ))
        index += 1

    return rectangles


function shuffle_color_rect_sequence(rectangles: ref[vec.Vec[ColorRect]], rect_count: int) -> void:
    let sequence = rl.load_random_sequence(uint<-rect_count, 0, rect_count - 1) else:
        fatal("could not allocate random sequence")
    defer rl.unload_random_sequence(sequence)

    var index = 0
    while index < rect_count:
        let first = rectangles.get(ptr_uint<-index) else:
            fatal("missing first random sequence rectangle")
        let second_index = unsafe: read(sequence + ptr_uint<-index)
        let second = rectangles.get(ptr_uint<-second_index) else:
            fatal("missing second random sequence rectangle")

        unsafe:
            let tmp = read(first)
            read(first).color = read(second).color
            read(first).rect.height = read(second).rect.height
            read(first).rect.y = read(second).rect.y
            read(second).color = tmp.color
            read(second).rect.height = tmp.rect.height
            read(second).rect.y = tmp.rect.y

        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - random sequence")
    defer rl.close_window()

    var rect_count = 20
    var rect_size = (float<-SCREEN_WIDTH) / (float<-rect_count)
    var rectangles = generate_random_color_rect_sequence(
        rect_count,
        rect_size,
        float<-SCREEN_WIDTH,
        0.75 * float<-SCREEN_HEIGHT
    )
    defer rectangles.release()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            shuffle_color_rect_sequence(ref_of(rectangles), rect_count)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            rect_count += 1
            rect_size = (float<-SCREEN_WIDTH) / (float<-rect_count)
            rectangles.release()
            rectangles = generate_random_color_rect_sequence(
                rect_count,
                rect_size,
                float<-SCREEN_WIDTH,
                0.75 * float<-SCREEN_HEIGHT
            )

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) and rect_count >= 4:
            rect_count -= 1
            rect_size = (float<-SCREEN_WIDTH) / (float<-rect_count)
            rectangles.release()
            rectangles = generate_random_color_rect_sequence(
                rect_count,
                rect_size,
                float<-SCREEN_WIDTH,
                0.75 * float<-SCREEN_HEIGHT
            )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < rect_count:
            let rectangle = rectangles.get(ptr_uint<-index) else:
                fatal("missing random sequence rectangle")

            unsafe:
                rl.draw_rectangle_rec(read(rectangle).rect, read(rectangle).color)

            index += 1

        rl.draw_text("Press SPACE to shuffle the current sequence", 10, SCREEN_HEIGHT - 96, 20, rl.BLACK)
        rl.draw_text("Press UP to add a rectangle and generate a new sequence", 10, SCREEN_HEIGHT - 64, 20, rl.BLACK)
        rl.draw_text(
            "Press DOWN to remove a rectangle and generate a new sequence",
            10,
            SCREEN_HEIGHT - 32,
            20,
            rl.BLACK
        )
        rl.draw_text(f"Count: #{rect_count} rectangles", 10, 10, 20, rl.MAROON)
        rl.draw_fps(SCREEN_WIDTH - 80, 10)

        rl.end_drawing()

    return 0
