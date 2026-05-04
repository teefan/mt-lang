module examples.idiomatic.raylib.particles_blending

import std.raylib as rl

struct Particle:
    position: rl.Vector2
    color: rl.Color
    alpha: f32
    size: f32
    rotation: f32
    active: bool

const max_particles: i32 = 200
const screen_width: i32 = 800
const screen_height: i32 = 450
const smoke_path: str = "../../raylib/resources/spark_flame.png"


def blend_label(blend_mode: i32) -> str:
    if blend_mode == rl.BlendMode.BLEND_ALPHA:
        return "ALPHA BLENDING"
    return "ADDITIVE BLENDING"


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Particles Blending")
    defer rl.close_window()

    var mouse_tail = zero[array[Particle, 200]]

    for index in 0..max_particles:
        mouse_tail[index].position = rl.Vector2(x = 0.0, y = 0.0)
        mouse_tail[index].color = rl.Color(
            r = u8<-rl.get_random_value(0, 255),
            g = u8<-rl.get_random_value(0, 255),
            b = u8<-rl.get_random_value(0, 255),
            a = 255,
        )
        mouse_tail[index].alpha = 1.0
        mouse_tail[index].size = f32<-rl.get_random_value(1, 30) / 20.0
        mouse_tail[index].rotation = f32<-rl.get_random_value(0, 360)
        mouse_tail[index].active = false

    let smoke = rl.load_texture(smoke_path)
    defer rl.unload_texture(smoke)

    let gravity: f32 = 3.0
    var blending: i32 = rl.BlendMode.BLEND_ALPHA

    rl.set_target_fps(60)

    while not rl.window_should_close():
        for index in 0..max_particles:
            if not mouse_tail[index].active:
                mouse_tail[index].active = true
                mouse_tail[index].alpha = 1.0
                mouse_tail[index].position = rl.get_mouse_position()
                break

        for index in 0..max_particles:
            if mouse_tail[index].active:
                mouse_tail[index].position.y += gravity / 2.0
                mouse_tail[index].alpha -= 0.005

                if mouse_tail[index].alpha <= 0.0:
                    mouse_tail[index].active = false

                mouse_tail[index].rotation += 2.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if blending == rl.BlendMode.BLEND_ALPHA:
                blending = rl.BlendMode.BLEND_ADDITIVE
            else:
                blending = rl.BlendMode.BLEND_ALPHA

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.DARKGRAY)

        rl.begin_blend_mode(blending)
        for index in 0..max_particles:
            if mouse_tail[index].active:
                let particle = mouse_tail[index]
                let width = f32<-smoke.width * particle.size
                let height = f32<-smoke.height * particle.size
                rl.draw_texture_pro(
                    smoke,
                    rl.Rectangle(x = 0.0, y = 0.0, width = f32<-smoke.width, height = f32<-smoke.height),
                    rl.Rectangle(x = particle.position.x, y = particle.position.y, width = width, height = height),
                    rl.Vector2(x = width / 2.0, y = height / 2.0),
                    particle.rotation,
                    rl.fade(particle.color, particle.alpha),
                )
        rl.end_blend_mode()

        rl.draw_text("PRESS SPACE to CHANGE BLENDING MODE", 180, 20, 20, rl.BLACK)
        rl.draw_text(blend_label(blending), if blending == rl.BlendMode.BLEND_ALPHA: 290 else: 280, screen_height - 40, 20, if blending == rl.BlendMode.BLEND_ALPHA: rl.BLACK else: rl.RAYWHITE)

    return 0
