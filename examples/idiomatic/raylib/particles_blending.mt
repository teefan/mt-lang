module examples.idiomatic.raylib.particles_blending

import std.raylib as rl

struct Particle:
    position: rl.Vector2
    color: rl.Color
    alpha: float
    size: float
    rotation: float
    active: bool

const max_particles: int = 200
const screen_width: int = 800
const screen_height: int = 450
const smoke_path: str = "../../raylib/resources/spark_flame.png"


def blend_label(blend_mode: int) -> str:
    if blend_mode == rl.BlendMode.BLEND_ALPHA:
        return "ALPHA BLENDING"
    return "ADDITIVE BLENDING"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Particles Blending")
    defer rl.close_window()

    var mouse_tail = zero[array[Particle, 200]]

    for index in 0..max_particles:
        mouse_tail[index].position = rl.Vector2(x = 0.0, y = 0.0)
        mouse_tail[index].color = rl.Color(
            r = ubyte<-rl.get_random_value(0, 255),
            g = ubyte<-rl.get_random_value(0, 255),
            b = ubyte<-rl.get_random_value(0, 255),
            a = 255,
        )
        mouse_tail[index].alpha = 1.0
        mouse_tail[index].size = float<-rl.get_random_value(1, 30) / 20.0
        mouse_tail[index].rotation = float<-rl.get_random_value(0, 360)
        mouse_tail[index].active = false

    let smoke = rl.load_texture(smoke_path)
    defer rl.unload_texture(smoke)

    let gravity: float = 3.0
    var blending: int = rl.BlendMode.BLEND_ALPHA

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
                let width = float<-smoke.width * particle.size
                let height = float<-smoke.height * particle.size
                rl.draw_texture_pro(
                    smoke,
                    rl.Rectangle(x = 0.0, y = 0.0, width = float<-smoke.width, height = float<-smoke.height),
                    rl.Rectangle(x = particle.position.x, y = particle.position.y, width = width, height = height),
                    rl.Vector2(x = width / 2.0, y = height / 2.0),
                    particle.rotation,
                    rl.fade(particle.color, particle.alpha),
                )
        rl.end_blend_mode()

        rl.draw_text("PRESS SPACE to CHANGE BLENDING MODE", 180, 20, 20, rl.BLACK)
        rl.draw_text(blend_label(blending), if blending == rl.BlendMode.BLEND_ALPHA: 290 else: 280, screen_height - 40, 20, if blending == rl.BlendMode.BLEND_ALPHA: rl.BLACK else: rl.RAYWHITE)

    return 0
