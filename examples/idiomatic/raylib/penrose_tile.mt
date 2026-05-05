module examples.idiomatic.raylib.penrose_tile

import std.raylib as rl
import std.raylib.math as math
import std.str as text
import std.string as string

struct TurtleState:
    origin: rl.Vector2
    angle: float

const screen_width: int = 800
const screen_height: int = 450
const turtle_stack_max_size: int = 50
const draw_length_base: float = 460.0
const min_generations: int = 0
const max_generations: int = 4
const byte_f: ubyte = 70
const byte_w: ubyte = 87
const byte_x: ubyte = 88
const byte_y: ubyte = 89
const byte_z: ubyte = 90
const byte_plus: ubyte = 43
const byte_minus: ubyte = 45
const byte_left_bracket: ubyte = 91
const byte_right_bracket: ubyte = 93
const byte_zero: ubyte = 48
const byte_nine: ubyte = 57


def append_rule(output: ref[string.String], step: ubyte) -> void:
    if step == byte_w:
        output.append("YF++ZF4-XF[-YF4-WF]++")
    elif step == byte_x:
        output.append("+YF--ZF[3-WF--XF]+")
    elif step == byte_y:
        output.append("-WF++XF[+++YF++ZF]-")
    elif step == byte_z:
        output.append("--YF++++WF[+ZF++++XF]--XF")
    elif step != byte_f:
        output.push_byte(step)


def build_production_step(production: string.String) -> string.String:
    let production_view = production.as_str()
    var next = string.String.with_capacity(production_view.len * 4)
    var index: ptr_uint = 0
    while index < production_view.len:
        append_rule(ref_of(next), text.byte_at(production_view, index))
        index += 1
    return next


def rebuild_production(generations: int) -> string.String:
    var production = string.String.from_str("[X]++[X]++[X]++[X]++[X]")
    for generation in 0..generations:
        var next = build_production_step(production)
        production.release()
        production = next
    return production


def push_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[int], state: TurtleState) -> void:
    if read(top) < turtle_stack_max_size - 1:
        var items = read(stack)
        read(top) += 1
        items[read(top)] = state
        read(stack) = items


def pop_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[int]) -> TurtleState:
    if read(top) >= 0:
        let items = read(stack)
        let state = items[read(top)]
        read(top) -= 1
        return state
    return zero[TurtleState]


def draw_penrose_lsystem(production: string.String, draw_length: float, steps: ref[int], turtle_stack: ref[array[TurtleState, 50]], turtle_top: ref[int]) -> void:
    let production_view = production.as_str()
    let screen_center = rl.Vector2(x = float<-rl.get_screen_width() / 2.0, y = float<-rl.get_screen_height() / 2.0)
    var turtle = TurtleState(origin = rl.Vector2(x = 0.0, y = 0.0), angle = -90.0)
    var repeats = 1

    read(steps) += 12
    if read(steps) > int<-production_view.len:
        read(steps) = int<-production_view.len

    for index in 0..read(steps):
        let step = text.byte_at(production_view, ptr_uint<-index)
        if step == byte_f:
            for repeat_index in 0..repeats:
                let start_pos_world = turtle.origin
                let rad_angle = math.deg2rad * turtle.angle
                turtle.origin.x += draw_length * math.cos(rad_angle)
                turtle.origin.y += draw_length * math.sin(rad_angle)

                let start_pos_screen = rl.Vector2(
                    x = start_pos_world.x + screen_center.x,
                    y = start_pos_world.y + screen_center.y,
                )
                let end_pos_screen = rl.Vector2(
                    x = turtle.origin.x + screen_center.x,
                    y = turtle.origin.y + screen_center.y,
                )
                rl.draw_line_ex(start_pos_screen, end_pos_screen, 2.0, rl.fade(rl.BLACK, 0.2))

            repeats = 1
        elif step == byte_plus:
            for repeat_index in 0..repeats:
                turtle.angle += 36.0

            repeats = 1
        elif step == byte_minus:
            for repeat_index in 0..repeats:
                turtle.angle -= 36.0

            repeats = 1
        elif step == byte_left_bracket:
            push_turtle_state(turtle_stack, turtle_top, turtle)
        elif step == byte_right_bracket:
            turtle = pop_turtle_state(turtle_stack, turtle_top)
        elif step >= byte_zero and step <= byte_nine:
            repeats = int<-(step - byte_zero)

    read(turtle_top) = -1


def draw_length_for(generations: int) -> float:
    return draw_length_base * float<-generations / float<-max_generations


def main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Penrose Tile")
    defer rl.close_window()

    var generations = 0
    var production = rebuild_production(generations)
    defer production.release()
    var steps = 0
    var turtle_stack = zero[array[TurtleState, 50]]
    var turtle_top = -1

    rl.set_target_fps(120)

    while not rl.window_should_close():
        var rebuild = false
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) and generations < max_generations:
            generations += 1
            rebuild = true
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) and generations > min_generations:
            generations -= 1
            rebuild = true

        if rebuild:
            production.release()
            production = rebuild_production(generations)
            steps = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if generations > 0:
            draw_penrose_lsystem(production, draw_length_for(generations), ref_of(steps), ref_of(turtle_stack), ref_of(turtle_top))

        rl.draw_text("penrose l-system", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("press up or down to change generations", 10, 30, 20, rl.DARKGRAY)
        rl.draw_text(rl.text_format_int("generations: %d", generations), 10, 50, 20, rl.DARKGRAY)

    return 0
