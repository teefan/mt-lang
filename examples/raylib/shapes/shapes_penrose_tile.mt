module examples.raylib.shapes.shapes_penrose_tile

import std.c.libm as math
import std.c.raylib as rl
import std.raylib.math as mt_math

struct TurtleState:
    origin: rl.Vector2
    angle: f32

struct PenroseLSystem:
    steps: i32
    production: ptr[char]
    rule_w: cstr
    rule_x: cstr
    rule_y: cstr
    rule_z: cstr
    draw_length: f32
    theta: f32

const screen_width: i32 = 800
const screen_height: i32 = 450
const str_max_size: i32 = 10000
const turtle_stack_max_size: i32 = 50
const draw_length_base: f32 = 460.0
const min_generations: i32 = 0
const max_generations: i32 = 4
const initial_production: cstr = c"[X]++[X]++[X]++[X]++[X]"
const window_title: cstr = c"raylib [shapes] example - penrose tile"
const title_text: cstr = c"penrose l-system"
const help_text: cstr = c"press up or down to change generations"
const generations_format: cstr = c"generations: %d"
const turtle_stack_overflow_text: cstr = c"TURTLE STACK OVERFLOW!"
const turtle_stack_underflow_text: cstr = c"TURTLE STACK UNDERFLOW!"

def append_text(buffer: ptr[char], position: ptr[i32], text: cstr) -> void:
    unsafe:
        let remaining = str_max_size - deref(position) - 1
        if remaining <= 0:
            return

        let text_length = cast[i32](rl.TextLength(text))
        if text_length <= remaining:
            rl.TextAppend(buffer, text, position)
        else:
            rl.TextAppend(buffer, rl.TextSubtext(text, 0, remaining), position)

def append_char(buffer: ptr[char], position: ptr[i32], ch: char) -> void:
    unsafe:
        let remaining = str_max_size - deref(position) - 1
        if remaining <= 0:
            return

        var scratch = zero[array[char, 2]]()
        scratch[0] = ch
        rl.TextAppend(buffer, cast[cstr](raw(addr(scratch[0]))), position)

def push_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[i32], state: TurtleState) -> void:
    if value(top) < turtle_stack_max_size - 1:
        var items = value(stack)
        value(top) += 1
        items[value(top)] = state
        value(stack) = items
    else:
        rl.TraceLog(rl.TraceLogLevel.LOG_WARNING, turtle_stack_overflow_text)

def pop_turtle_state(stack: ref[array[TurtleState, 50]], top: ref[i32]) -> TurtleState:
    if value(top) >= 0:
        let items = value(stack)
        let state = items[value(top)]
        value(top) -= 1
        return state

    rl.TraceLog(rl.TraceLogLevel.LOG_WARNING, turtle_stack_underflow_text)
    return zero[TurtleState]()

def create_penrose_lsystem(draw_length: f32) -> PenroseLSystem:
    var production = zero[ptr[char]]()
    unsafe:
        production = cast[ptr[char]](rl.MemAlloc(cast[u32](str_max_size)))
        production[0] = cast[char](0)
        rl.TextCopy(production, initial_production)

    return PenroseLSystem(
        steps = 0,
        production = production,
        rule_w = c"YF++ZF4-XF[-YF4-WF]++",
        rule_x = c"+YF--ZF[3-WF--XF]+",
        rule_y = c"-WF++XF[+++YF++ZF]-",
        rule_z = c"--YF++++WF[+ZF++++XF]--XF",
        draw_length = draw_length,
        theta = 36.0,
    )

def build_production_step(ls: ref[PenroseLSystem]) -> void:
    var new_production = zero[ptr[char]]()
    unsafe:
        new_production = cast[ptr[char]](rl.MemAlloc(cast[u32](str_max_size)))
        new_production[0] = cast[char](0)

        let production_length = cast[i32](rl.TextLength(cast[cstr](value(ls).production)))
        var new_length = 0

        for index in range(0, production_length):
            let step = value(ls).production[index]
            if step == cast[char](87):
                append_text(new_production, raw(addr(new_length)), value(ls).rule_w)
            elif step == cast[char](88):
                append_text(new_production, raw(addr(new_length)), value(ls).rule_x)
            elif step == cast[char](89):
                append_text(new_production, raw(addr(new_length)), value(ls).rule_y)
            elif step == cast[char](90):
                append_text(new_production, raw(addr(new_length)), value(ls).rule_z)
            elif step != cast[char](70):
                append_char(new_production, raw(addr(new_length)), step)

        value(ls).draw_length *= 0.5
        rl.TextCopy(value(ls).production, cast[cstr](new_production))
        rl.MemFree(cast[ptr[void]](new_production))

def draw_penrose_lsystem(ls: ref[PenroseLSystem], turtle_stack: ref[array[TurtleState, 50]], turtle_top: ref[i32]) -> void:
    let screen_center = rl.Vector2(x = rl.GetScreenWidth() / 2.0, y = rl.GetScreenHeight() / 2.0)
    var turtle = TurtleState(origin = rl.Vector2(x = 0.0, y = 0.0), angle = -90.0)
    var repeats = 1

    unsafe:
        let production_length = cast[i32](rl.TextLength(cast[cstr](value(ls).production)))
        value(ls).steps += 12
        if value(ls).steps > production_length:
            value(ls).steps = production_length

        for index in range(0, value(ls).steps):
            let step = value(ls).production[index]
            if step == cast[char](70):
                for repeat_index in range(0, repeats):
                    let start_pos_world = turtle.origin
                    let rad_angle = mt_math.deg2rad * turtle.angle
                    turtle.origin.x += value(ls).draw_length * math.cosf(rad_angle)
                    turtle.origin.y += value(ls).draw_length * math.sinf(rad_angle)

                    let start_pos_screen = rl.Vector2(
                        x = start_pos_world.x + screen_center.x,
                        y = start_pos_world.y + screen_center.y,
                    )
                    let end_pos_screen = rl.Vector2(
                        x = turtle.origin.x + screen_center.x,
                        y = turtle.origin.y + screen_center.y,
                    )
                    rl.DrawLineEx(start_pos_screen, end_pos_screen, 2.0, rl.Fade(rl.BLACK, 0.2))

                repeats = 1
            elif step == cast[char](43):
                for repeat_index in range(0, repeats):
                    turtle.angle += value(ls).theta

                repeats = 1
            elif step == cast[char](45):
                for repeat_index in range(0, repeats):
                    turtle.angle -= value(ls).theta

                repeats = 1
            elif step == cast[char](91):
                push_turtle_state(turtle_stack, turtle_top, turtle)
            elif step == cast[char](93):
                turtle = pop_turtle_state(turtle_stack, turtle_top)
            elif cast[i32](step) >= 48 and cast[i32](step) <= 57:
                repeats = cast[i32](step) - 48

    value(turtle_top) = -1

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var generations = 0
    var ls = create_penrose_lsystem(draw_length_base * cast[f32](generations) / cast[f32](max_generations))
    for index in range(0, generations):
        build_production_step(addr(ls))

    var turtle_stack = zero[array[TurtleState, 50]]()
    var turtle_top = -1

    rl.SetTargetFPS(120)

    while not rl.WindowShouldClose():
        var rebuild = false
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            if generations < max_generations:
                generations += 1
                rebuild = true
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            if generations > min_generations:
                generations -= 1
                if generations > 0:
                    rebuild = true

        if rebuild:
            unsafe:
                rl.MemFree(cast[ptr[void]](ls.production))
            ls = create_penrose_lsystem(draw_length_base * cast[f32](generations) / cast[f32](max_generations))
            for index in range(0, generations):
                build_production_step(addr(ls))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if generations > 0:
            draw_penrose_lsystem(addr(ls), addr(turtle_stack), addr(turtle_top))

        rl.DrawText(title_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(help_text, 10, 30, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(generations_format, generations), 10, 50, 20, rl.DARKGRAY)

    unsafe:
        rl.MemFree(cast[ptr[void]](ls.production))

    return 0
