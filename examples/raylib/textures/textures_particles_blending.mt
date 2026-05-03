module examples.raylib.textures.textures_particles_blending

import std.c.raylib as rl

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
const window_title: cstr = c"raylib [textures] example - particles blending"
const smoke_path: cstr = c"../resources/spark_flame.png"
const help_text: cstr = c"PRESS SPACE to CHANGE BLENDING MODE"


def blend_label(blend_mode: i32) -> cstr:
    if blend_mode == rl.BlendMode.BLEND_ALPHA:
        return c"ALPHA BLENDING"
    return c"ADDITIVE BLENDING"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var mouse_tail = zero[array[Particle, 200]]()

    for index in range(0, max_particles):
        mouse_tail[index].position = rl.Vector2(x = 0.0, y = 0.0)
        mouse_tail[index].color = rl.Color(
            r = u8<-rl.GetRandomValue(0, 255),
            g = u8<-rl.GetRandomValue(0, 255),
            b = u8<-rl.GetRandomValue(0, 255),
            a = 255,
        )
        mouse_tail[index].alpha = 1.0
        mouse_tail[index].size = f32<-rl.GetRandomValue(1, 30) / 20.0
        mouse_tail[index].rotation = f32<-rl.GetRandomValue(0, 360)
        mouse_tail[index].active = false

    let smoke = rl.LoadTexture(smoke_path)
    defer rl.UnloadTexture(smoke)

    let gravity: f32 = 3.0
    var blending: i32 = rl.BlendMode.BLEND_ALPHA

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        for index in range(0, max_particles):
            if not mouse_tail[index].active:
                mouse_tail[index].active = true
                mouse_tail[index].alpha = 1.0
                mouse_tail[index].position = rl.GetMousePosition()
                break

        for index in range(0, max_particles):
            if mouse_tail[index].active:
                mouse_tail[index].position.y += gravity / 2.0
                mouse_tail[index].alpha -= 0.005

                if mouse_tail[index].alpha <= 0.0:
                    mouse_tail[index].active = false

                mouse_tail[index].rotation += 2.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            if blending == rl.BlendMode.BLEND_ALPHA:
                blending = rl.BlendMode.BLEND_ADDITIVE
            else:
                blending = rl.BlendMode.BLEND_ALPHA

        rl.BeginDrawing()
        rl.ClearBackground(rl.DARKGRAY)

        rl.BeginBlendMode(blending)
        for index in range(0, max_particles):
            if mouse_tail[index].active:
                let particle = mouse_tail[index]
                let width = f32<-smoke.width * particle.size
                let height = f32<-smoke.height * particle.size
                rl.DrawTexturePro(
                    smoke,
                    rl.Rectangle(x = 0.0, y = 0.0, width = f32<-smoke.width, height = f32<-smoke.height),
                    rl.Rectangle(x = particle.position.x, y = particle.position.y, width = width, height = height),
                    rl.Vector2(x = width / 2.0, y = height / 2.0),
                    particle.rotation,
                    rl.Fade(particle.color, particle.alpha),
                )
        rl.EndBlendMode()

        rl.DrawText(help_text, 180, 20, 20, rl.BLACK)
        rl.DrawText(blend_label(blending), if blending == rl.BlendMode.BLEND_ALPHA: 290 else: 280, screen_height - 40, 20, if blending == rl.BlendMode.BLEND_ALPHA: rl.BLACK else: rl.RAYWHITE)

        rl.EndDrawing()

    return 0
