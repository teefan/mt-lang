import std.math as math
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const STR_MAX_SIZE: int = 10000
const TURTLE_STACK_MAX_SIZE: int = 50
const ASCII_W: ubyte = ubyte<-87
const ASCII_X: ubyte = ubyte<-88
const ASCII_Y: ubyte = ubyte<-89
const ASCII_Z: ubyte = ubyte<-90
const ASCII_F: ubyte = ubyte<-70
const ASCII_PLUS: ubyte = ubyte<-43
const ASCII_MINUS: ubyte = ubyte<-45
const ASCII_LBRACKET: ubyte = ubyte<-91
const ASCII_RBRACKET: ubyte = ubyte<-93
const ASCII_ZERO: ubyte = ubyte<-48
const ASCII_NINE: ubyte = ubyte<-57


struct TurtleState:
    origin: rl.Vector2
    angle: float


struct PenroseLSystem:
    steps: int
    production: str_buffer[10000]
    rule_w: str
    rule_x: str
    rule_y: str
    rule_z: str
    draw_length: float
    theta: float


var turtle_stack: array[TurtleState, TURTLE_STACK_MAX_SIZE] = zero[array[TurtleState, TURTLE_STACK_MAX_SIZE]]
var turtle_top: int = -1


function push_turtle_state(state: TurtleState) -> void:
    if turtle_top < TURTLE_STACK_MAX_SIZE - 1:
        turtle_top += 1
        turtle_stack[turtle_top] = state
    else:
        rl.trace_log(int<-rl.TraceLogLevel.LOG_WARNING, "TURTLE STACK OVERFLOW!")


function pop_turtle_state() -> TurtleState:
    if turtle_top >= 0:
        let state = turtle_stack[turtle_top]
        turtle_top -= 1
        return state

    rl.trace_log(int<-rl.TraceLogLevel.LOG_WARNING, "TURTLE STACK UNDERFLOW!")
    return zero[TurtleState]


function create_penrose_lsystem(draw_length: float) -> PenroseLSystem:
    var result = PenroseLSystem(
        steps = 0,
        production = zero[str_buffer[10000]],
        rule_w = "YF++ZF4-XF[-YF4-WF]++",
        rule_x = "+YF--ZF[3-WF--XF]+",
        rule_y = "-WF++XF[+++YF++ZF]-",
        rule_z = "--YF++++WF[+ZF++++XF]--XF",
        draw_length = draw_length,
        theta = 36.0,
    )
    result.production.assign("[X]++[X]++[X]++[X]++[X]")
    return result


function build_production_step(ls: ref[PenroseLSystem]) -> void:
    var new_production = zero[str_buffer[10000]]
    let production_text = read(ls).production.as_str()

    var index: ptr_uint = 0
    while index < production_text.len:
        let step = production_text.byte_at(index)
        if step == ASCII_W:
            new_production.append(read(ls).rule_w)
        else if step == ASCII_X:
            new_production.append(read(ls).rule_x)
        else if step == ASCII_Y:
            new_production.append(read(ls).rule_y)
        else if step == ASCII_Z:
            new_production.append(read(ls).rule_z)
        else if step != ASCII_F:
            new_production.append(production_text.slice(index, ptr_uint<-1))
        index += 1

    read(ls).draw_length *= 0.5
    read(ls).production.assign(new_production.as_str())


function draw_penrose_lsystem(ls: ref[PenroseLSystem]) -> void:
    let screen_center = rl.Vector2(x = float<-rl.get_screen_width() / 2.0, y = float<-rl.get_screen_height() / 2.0)
    var turtle = TurtleState(origin = zero[rl.Vector2], angle = -90.0)
    var repeats = 1
    let production_text = read(ls).production.as_str()

    read(ls).steps += 12
    if read(ls).steps > int<-production_text.len:
        read(ls).steps = int<-production_text.len

    var index = 0
    while index < read(ls).steps:
        let step = production_text.byte_at(ptr_uint<-index)
        if step == ASCII_F:
            var repeat_index = 0
            while repeat_index < repeats:
                let start_pos_world = turtle.origin
                let rad_angle = turtle.angle * rl.PI / 180.0
                turtle.origin.x += read(ls).draw_length * float<-math.cos(double<-rad_angle)
                turtle.origin.y += read(ls).draw_length * float<-math.sin(double<-rad_angle)

                let start_pos_screen = rl.Vector2(x = start_pos_world.x + screen_center.x, y = start_pos_world.y + screen_center.y)
                let end_pos_screen = rl.Vector2(x = turtle.origin.x + screen_center.x, y = turtle.origin.y + screen_center.y)
                rl.draw_line_ex(start_pos_screen, end_pos_screen, 2.0, rl.fade(rl.BLACK, 0.2))
                repeat_index += 1
            repeats = 1
        else if step == ASCII_PLUS:
            var repeat_index = 0
            while repeat_index < repeats:
                turtle.angle += read(ls).theta
                repeat_index += 1
            repeats = 1
        else if step == ASCII_MINUS:
            var repeat_index = 0
            while repeat_index < repeats:
                turtle.angle -= read(ls).theta
                repeat_index += 1
            repeats = 1
        else if step == ASCII_LBRACKET:
            push_turtle_state(turtle)
        else if step == ASCII_RBRACKET:
            turtle = pop_turtle_state()
        else if step >= ASCII_ZERO and step <= ASCII_NINE:
            repeats = int<-(step - ASCII_ZERO)
        index += 1

    turtle_top = -1


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - penrose tile")
    defer rl.close_window()

    let draw_length: float = 460.0
    let min_generations = 0
    let max_generations = 4
    var generations = 0

    var ls = create_penrose_lsystem(draw_length * (float<-generations / float<-max_generations))
    var index = 0
    while index < generations:
        build_production_step(ref_of(ls))
        index += 1

    rl.set_target_fps(120)

    while not rl.window_should_close():
        var rebuild = false
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            if generations < max_generations:
                generations += 1
                rebuild = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            if generations > min_generations:
                generations -= 1
                if generations > 0:
                    rebuild = true

        if rebuild:
            ls = create_penrose_lsystem(draw_length * (float<-generations / float<-max_generations))
            index = 0
            while index < generations:
                build_production_step(ref_of(ls))
                index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if generations > 0:
            draw_penrose_lsystem(ref_of(ls))

        rl.draw_text("penrose l-system", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("press up or down to change generations", 10, 30, 20, rl.DARKGRAY)
        rl.draw_text(text.cstr_as_str(rl.text_format("generations: %d", generations)), 10, 50, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
