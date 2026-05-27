import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_PARTICLES: int = 200


struct Particle:
    position: rl.Vector2
    color: rl.Color
    alpha: float
    size: float
    rotation: float
    active: bool


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - particles blending")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var mouse_tail: array[Particle, MAX_PARTICLES] = zero[array[Particle, MAX_PARTICLES]]

    var index = 0
    while index < MAX_PARTICLES:
        mouse_tail[index].position = rl.Vector2(x = float<-0.0, y = float<-0.0)
        mouse_tail[index].color = rl.Color(
            r = ubyte<-rl.get_random_value(0, 255),
            g = ubyte<-rl.get_random_value(0, 255),
            b = ubyte<-rl.get_random_value(0, 255),
            a = 255,
        )
        mouse_tail[index].alpha = float<-1.0
        mouse_tail[index].size = float<-rl.get_random_value(1, 30) / float<-20.0
        mouse_tail[index].rotation = float<-rl.get_random_value(0, 360)
        mouse_tail[index].active = false
        index += 1

    let gravity = float<-3.0

    let smoke = rl.load_texture("spark_flame.png")
    defer rl.unload_texture(smoke)

    var blending = int<-rl.BlendMode.BLEND_ALPHA

    rl.set_target_fps(60)

    while not rl.window_should_close():
        index = 0
        while index < MAX_PARTICLES:
            if not mouse_tail[index].active:
                mouse_tail[index].active = true
                mouse_tail[index].alpha = float<-1.0
                mouse_tail[index].position = rl.get_mouse_position()
                break
            index += 1

        index = 0
        while index < MAX_PARTICLES:
            if mouse_tail[index].active:
                mouse_tail[index].position.y += gravity / float<-2.0
                mouse_tail[index].alpha -= float<-0.005

                if mouse_tail[index].alpha <= float<-0.0:
                    mouse_tail[index].active = false

                mouse_tail[index].rotation += float<-2.0
            index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if blending == int<-rl.BlendMode.BLEND_ALPHA:
                blending = int<-rl.BlendMode.BLEND_ADDITIVE
            else:
                blending = int<-rl.BlendMode.BLEND_ALPHA

        rl.begin_drawing()
        rl.clear_background(rl.DARKGRAY)

        rl.begin_blend_mode(blending)

        index = 0
        while index < MAX_PARTICLES:
            if mouse_tail[index].active:
                let source = rl.Rectangle(x = 0.0, y = 0.0, width = float<-smoke.width, height = float<-smoke.height)
                let destination = rl.Rectangle(
                    x = mouse_tail[index].position.x,
                    y = mouse_tail[index].position.y,
                    width = float<-smoke.width * mouse_tail[index].size,
                    height = float<-smoke.height * mouse_tail[index].size,
                )
                let origin = rl.Vector2(
                    x = float<-smoke.width * mouse_tail[index].size / 2.0,
                    y = float<-smoke.height * mouse_tail[index].size / 2.0,
                )
                rl.draw_texture_pro(smoke, source, destination, origin, mouse_tail[index].rotation, rl.fade(mouse_tail[index].color, mouse_tail[index].alpha))
            index += 1

        rl.end_blend_mode()

        rl.draw_text("PRESS SPACE to CHANGE BLENDING MODE", 180, 20, 20, rl.BLACK)
        if blending == int<-rl.BlendMode.BLEND_ALPHA:
            rl.draw_text("ALPHA BLENDING", 290, SCREEN_HEIGHT - 40, 20, rl.BLACK)
        else:
            rl.draw_text("ADDITIVE BLENDING", 280, SCREEN_HEIGHT - 40, 20, rl.RAYWHITE)

        rl.end_drawing()

    return 0
