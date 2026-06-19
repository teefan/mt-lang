import std.math as math
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_PARTICLES: int = 3000
const WATER: int = 0
const SMOKE: int = 1
const FIRE: int = 2
const DEG_TO_RAD: float = rl.PI / 180.0

struct Particle:
    particle_type: int
    position: rl.Vector2
    velocity: rl.Vector2
    radius: float
    color: rl.Color
    life_time: float
    alive: bool

var particles: array[Particle, MAX_PARTICLES] = zero[array[Particle, MAX_PARTICLES]]


function particle_type_name(particle_type: int) -> str:
    if particle_type == WATER:
        return "WATER"
    else if particle_type == SMOKE:
        return "SMOKE"

    return "FIRE"


function add_to_circular_buffer(head: ref[int], tail: int) -> int:
    let next_head = (read(head) + 1) % MAX_PARTICLES
    if next_head == tail:
        return -1

    let particle_index = read(head)
    unsafe: read(head) = next_head
    return particle_index


function emit_particle(head: ref[int], tail: int, emitter_position: rl.Vector2, particle_type: int) -> void:
    let particle_index = add_to_circular_buffer(head, tail)
    if particle_index == -1:
        return

    particles[particle_index].position = emitter_position
    particles[particle_index].alive = true
    particles[particle_index].life_time = 0.0
    particles[particle_index].particle_type = particle_type

    var speed: float = float<-rl.get_random_value(0, 9) / 5.0
    if particle_type == WATER:
        particles[particle_index].radius = 5.0
        particles[particle_index].color = rl.BLUE
    else if particle_type == SMOKE:
        particles[particle_index].radius = 7.0
        particles[particle_index].color = rl.GRAY
    else:
        particles[particle_index].radius = 10.0
        particles[particle_index].color = rl.YELLOW
        speed /= 10.0

    let direction = float<-rl.get_random_value(0, 359)
    particles[particle_index].velocity = rl.Vector2(
        x = speed * float<-math.cos(double<-(direction * DEG_TO_RAD)),
        y = speed * float<-math.sin(double<-(direction * DEG_TO_RAD))
    )


function update_particles(head: int, tail: int, screen_width: int, screen_height: int) -> void:
    var index = tail
    while index != head:
        particles[index].life_time += 1.0 / 60.0

        if particles[index].particle_type == WATER:
            particles[index].position.x += particles[index].velocity.x
            particles[index].velocity.y += 0.2
            particles[index].position.y += particles[index].velocity.y
        else if particles[index].particle_type == SMOKE:
            particles[index].position.x += particles[index].velocity.x
            particles[index].velocity.y -= 0.05
            particles[index].position.y += particles[index].velocity.y
            particles[index].radius += 0.5
            particles[index].color.a -= 4ub

            if particles[index].color.a < 4ub:
                particles[index].alive = false
        else:
            particles[index].position.x += (
                particles[index].velocity.x
                + float<-math.cos(double<-(particles[index].life_time * 215.0))
            )
            particles[index].velocity.y -= 0.05
            particles[index].position.y += particles[index].velocity.y
            particles[index].radius -= 0.15
            particles[index].color.g -= 3ub

            if particles[index].radius <= 0.02:
                particles[index].alive = false

        let center = particles[index].position
        let radius = particles[index].radius
        if (
            center.x < -radius
            or center.x > float<-screen_width + radius
            or center.y < -radius
            or center.y > float<-screen_height + radius
        ):
            particles[index].alive = false

        index = (index + 1) % MAX_PARTICLES


function update_circular_buffer(head: int, tail: ref[int]) -> void:
    while read(tail) != head and not particles[read(tail)].alive:
        unsafe: read(tail) = (read(tail) + 1) % MAX_PARTICLES


function draw_particles(head: int, tail: int) -> void:
    var index = tail
    while index != head:
        if particles[index].alive:
            rl.draw_circle_v(particles[index].position, particles[index].radius, particles[index].color)
        index = (index + 1) % MAX_PARTICLES


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - simple particles")
    defer rl.close_window()

    var head = 0
    var tail = 0
    var emission_rate = -2
    var current_type = WATER
    var emitter_position = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if emission_rate < 0:
            if rl.get_random_value(0, -emission_rate - 1) == 0:
                emit_particle(ref_of(head), tail, emitter_position, current_type)
        else:
            var count = 0
            while count <= emission_rate:
                emit_particle(ref_of(head), tail, emitter_position, current_type)
                count += 1

        update_particles(head, tail, SCREEN_WIDTH, SCREEN_HEIGHT)
        update_circular_buffer(head, ref_of(tail))

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            emission_rate += 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            emission_rate -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            if current_type == FIRE:
                current_type = WATER
            else:
                current_type += 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if current_type == WATER:
                current_type = FIRE
            else:
                current_type -= 1

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            emitter_position = rl.get_mouse_position()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        draw_particles(head, tail)

        rl.draw_rectangle(5, 5, 315, 75, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 315, 75, rl.BLUE)
        rl.draw_text("CONTROLS:", 15, 15, 10, rl.BLACK)
        rl.draw_text("UP/DOWN: Change Particle Emission Rate", 15, 35, 10, rl.BLACK)
        rl.draw_text("LEFT/RIGHT: Change Particle Type (Water, Smoke, Fire)", 15, 55, 10, rl.BLACK)

        var particle_status: str = ""
        if emission_rate < 0:
            particle_status = text.cstr_as_str(
                rl.text_format(
                    "Particles every %d frames | Type: %s",
                    -emission_rate,
                    particle_type_name(current_type)
                )
            )
        else:
            particle_status = text.cstr_as_str(
                rl.text_format(
                    "%d Particles per frame | Type: %s",
                    emission_rate + 1,
                    particle_type_name(current_type)
                )
            )
        rl.draw_text(particle_status, 15, 95, 10, rl.DARKGRAY)

        rl.draw_fps(SCREEN_WIDTH - 80, 10)
        rl.end_drawing()

    return 0
