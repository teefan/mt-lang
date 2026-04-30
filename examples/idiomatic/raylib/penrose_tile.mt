module examples.idiomatic.raylib.penrose_tile

import std.raylib as rl
import std.raylib.math as math
import std.str as text
import std.string as string

struct TurtleState:
    origin: rl.Vector2
    angle: f32

const screen_width: i32 = 800
const screen_height: i32 = 450
const turtle_stack_max_size: i32 = 50
const draw_length_base: f32 = 460.0
const min_generations: i32 = 0
const max_generations: i32 = 4
const byte_f: u8 = 70
const byte_w: u8 = 87
const byte_x: u8 = 88
const byte_y: u8 = 89
const byte_z: u8 = 90
const byte_plus: u8 = 43
const byte_minus: u8 = 45
const byte_left_bracket: u8 = 91
const byte_right_bracket: u8 = 93
const byte_zero: u8 = 48
const byte_nine: u8 = 57

def append_rule(output: ref[string.String], step: u8) -> void:
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
    var index: usize = 0
    while index < production_view.len:
        append_rule(ref_of(next), text.byte_at(production_view, index))
        index += 1
    return next

def rebuild_production(generations: i32) -> string.String:
    var production = string.String.from_str("[X]++[X]++[X]++[X]++[X]")
    for generation in range(0, generations):
        var next = build_production_step(production)
        production.release()
        production = next
    return production

def push_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[i32], state: TurtleState) -> void:
    if read(top) < turtle_stack_max_size - 1:
        var items = read(stack)
        read(top) += 1
        items[read(top)] = state
        read(stack) = items

def pop_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[i32]) -> TurtleState:
    if read(top) >= 0:
        let items = read(stack)
        let state = items[read(top)]
        read(top) -= 1
        return state
    return zero[TurtleState]()

def draw_penrose_lsystem(production: string.String, draw_length: f32, steps: ref[i32], turtle_stack: ref[array[TurtleState, 50]], turtle_top: ref[i32]) -> void:
    let production_view = production.as_str()
    let screen_center = rl.Vector2(x = f32<-rl.get_screen_width() / 2.0, y = f32<-rl.get_screen_height() / 2.0)
    var turtle = TurtleState(origin = rl.Vector2(x = 0.0, y = 0.0), angle = -90.0)
    var repeats = 1

    read(steps) += 12
    if read(steps) > i32<-production_view.len:
        read(steps) = i32<-production_view.len

    for index in range(0, read(steps)):
        let step = text.byte_at(production_view, usize<-index)
        if step == byte_f:
            for repeat_index in range(0, repeats):
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
            for repeat_index in range(0, repeats):
                turtle.angle += 36.0

            repeats = 1
        elif step == byte_minus:
            for repeat_index in range(0, repeats):
                turtle.angle -= 36.0

            repeats = 1
        elif step == byte_left_bracket:
            push_turtle_state(turtle_stack, turtle_top, turtle)
        elif step == byte_right_bracket:
            turtle = pop_turtle_state(turtle_stack, turtle_top)
        elif step >= byte_zero and step <= byte_nine:
            repeats = i32<-(step - byte_zero)

    read(turtle_top) = -1

def draw_length_for(generations: i32) -> f32:
    return draw_length_base * f32<-generations / f32<-max_generations

def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Penrose Tile")
    defer rl.close_window()

    var generations = 0
    var production = rebuild_production(generations)
    defer production.release()
    var steps = 0
    var turtle_stack = zero[array[TurtleState, 50]]()
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
        rl.draw_text(rl.text_format_i32("generations: %d", generations), 10, 50, 20, rl.DARKGRAY)

    return 0
