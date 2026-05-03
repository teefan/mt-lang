module examples.idiomatic.raylib.simple_particles

import std.mem.heap as heap
import std.raylib as rl
import std.raylib.math as math
import std.span as sp

enum ParticleType: i32
    WATER = 0
    SMOKE = 1
    FIRE = 2

struct Particle:
    kind: i32
    position: rl.Vector2
    velocity: rl.Vector2
    radius: f32
    color: rl.Color
    life_time: f32
    alive: bool

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_particles: i32 = 3000

def particle_type_name(particle_type: i32) -> str:
    if particle_type == ParticleType.WATER:
        return "WATER"
    if particle_type == ParticleType.SMOKE:
        return "SMOKE"
    return "FIRE"

def next_buffer_index(index: i32) -> i32:
    return (index + 1) % max_particles

def add_to_circular_buffer(head: ref[i32], tail: i32) -> i32:
    if next_buffer_index(read(head)) != tail:
        let particle_index = read(head)
        read(head) = next_buffer_index(read(head))
        return particle_index
    return -1

def emit_particle(particles: ptr[Particle], head: ref[i32], tail: i32, emitter_position: rl.Vector2, particle_type: i32) -> void:
    let particle_index = add_to_circular_buffer(head, tail)
    if particle_index < 0:
        return

    var particles_view = sp.from_ptr[Particle](particles, usize<-max_particles)
    particles_view[particle_index].position = emitter_position
    particles_view[particle_index].alive = true
    particles_view[particle_index].life_time = 0.0
    particles_view[particle_index].kind = particle_type

    var speed = f32<-rl.get_random_value(0, 9) / 5.0
    if particle_type == ParticleType.WATER:
        particles_view[particle_index].radius = 5.0
        particles_view[particle_index].color = rl.BLUE
    elif particle_type == ParticleType.SMOKE:
        particles_view[particle_index].radius = 7.0
        particles_view[particle_index].color = rl.GRAY
    else:
        particles_view[particle_index].radius = 10.0
        particles_view[particle_index].color = rl.YELLOW
        speed /= 10.0

    let direction = f32<-rl.get_random_value(0, 359) * math.deg2rad
    particles_view[particle_index].velocity = rl.Vector2(
        x = speed * math.cos(direction),
        y = speed * math.sin(direction),
    )
    return

def update_particles(particles: ptr[Particle], head: i32, tail: i32, width: i32, height: i32) -> void:
    var particles_view = sp.from_ptr[Particle](particles, usize<-max_particles)
    var index = tail
    while index != head:
        particles_view[index].life_time += 1.0 / 60.0

        if particles_view[index].kind == ParticleType.WATER:
            particles_view[index].position.x += particles_view[index].velocity.x
            particles_view[index].velocity.y += 0.2
            particles_view[index].position.y += particles_view[index].velocity.y
        elif particles_view[index].kind == ParticleType.SMOKE:
            particles_view[index].position.x += particles_view[index].velocity.x
            particles_view[index].velocity.y -= 0.05
            particles_view[index].position.y += particles_view[index].velocity.y
            particles_view[index].radius += 0.5

            if particles_view[index].color.a < 4:
                particles_view[index].alive = false
            else:
                particles_view[index].color.a = u8<-(i32<-particles_view[index].color.a - 4)
        else:
            particles_view[index].position.x += particles_view[index].velocity.x + math.cos(particles_view[index].life_time * 215.0)
            particles_view[index].velocity.y -= 0.05
            particles_view[index].position.y += particles_view[index].velocity.y
            particles_view[index].radius -= 0.15

            if particles_view[index].color.g > 3:
                particles_view[index].color.g = u8<-(i32<-particles_view[index].color.g - 3)
            else:
                particles_view[index].color.g = 0

            if particles_view[index].radius <= 0.02:
                particles_view[index].alive = false

        let center = particles_view[index].position
        let radius = particles_view[index].radius
        if center.x < -radius or center.x > width + radius or center.y < -radius or center.y > height + radius:
            particles_view[index].alive = false

        index = next_buffer_index(index)
    return

def update_circular_buffer(particles: ptr[Particle], head: i32, tail: ref[i32]) -> void:
    let particles_view = sp.from_ptr[Particle](particles, usize<-max_particles)
    while read(tail) != head and not particles_view[read(tail)].alive:
        read(tail) = next_buffer_index(read(tail))
    return

def draw_particles(particles: ptr[Particle], head: i32, tail: i32) -> void:
    let particles_view = sp.from_ptr[Particle](particles, usize<-max_particles)
    var index = tail
    while index != head:
        if particles_view[index].alive:
            rl.draw_circle_v(particles_view[index].position, particles_view[index].radius, particles_view[index].color)
        index = next_buffer_index(index)
    return

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Simple Particles")
    defer rl.close_window()

    let particles = heap.must_alloc_zeroed[Particle](usize<-max_particles)
    defer heap.release(particles)

    var head = 0
    var tail = 0
    var emission_rate = -2
    var current_type = ParticleType.WATER
    var emitter_position = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if emission_rate < 0:
            if rl.get_random_value(0, -emission_rate - 1) == 0:
                emit_particle(particles, ref_of(head), tail, emitter_position, current_type)
        else:
            for index in range(0, emission_rate + 1):
                let _ = index
                emit_particle(particles, ref_of(head), tail, emitter_position, current_type)

        update_particles(particles, head, tail, screen_width, screen_height)
        update_circular_buffer(particles, head, ref_of(tail))

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            emission_rate += 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            emission_rate -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            if current_type == ParticleType.FIRE:
                current_type = ParticleType.WATER
            elif current_type == ParticleType.WATER:
                current_type = ParticleType.SMOKE
            else:
                current_type = ParticleType.FIRE
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if current_type == ParticleType.WATER:
                current_type = ParticleType.FIRE
            elif current_type == ParticleType.FIRE:
                current_type = ParticleType.SMOKE
            else:
                current_type = ParticleType.WATER

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            emitter_position = rl.get_mouse_position()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        draw_particles(particles, head, tail)
        rl.draw_rectangle(5, 5, 315, 75, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 315, 75, rl.BLUE)
        rl.draw_text("CONTROLS:", 15, 15, 10, rl.BLACK)
        rl.draw_text("UP/DOWN: Change Particle Emission Rate", 15, 35, 10, rl.BLACK)
        rl.draw_text("LEFT/RIGHT: Change Particle Type (Water, Smoke, Fire)", 15, 55, 10, rl.BLACK)

        if emission_rate < 0:
            rl.draw_text(rl.text_format_i32_cstr("Particles every %d frames | Type: %s", -emission_rate, particle_type_name(current_type)), 15, 95, 10, rl.DARKGRAY)
        else:
            rl.draw_text(rl.text_format_i32_cstr("%d Particles per frame | Type: %s", emission_rate + 1, particle_type_name(current_type)), 15, 95, 10, rl.DARKGRAY)

        rl.draw_fps(screen_width - 80, 10)

    return 0