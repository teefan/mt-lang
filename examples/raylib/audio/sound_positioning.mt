import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function set_sound_position(listener: rl.Camera, sound: rl.Sound, position: rl.Vector3, max_dist: float) -> void:
    let direction = rm.vector3_subtract(position, listener.position)
    let distance = rm.vector3_length(direction)

    var attenuation: float = 1.0 / (1.0 + (distance / max_dist))
    attenuation = rm.clamp(attenuation, 0.0, 1.0)

    let normalized_direction = rm.vector3_normalize(direction)
    let forward = rm.vector3_normalize(rm.vector3_subtract(listener.target, listener.position))
    let right = rm.vector3_normalize(rm.vector3_cross_product(listener.up, forward))

    let dot_product = rm.vector3_dot_product(forward, normalized_direction)
    if dot_product < 0.0:
        attenuation *= 1.0 + dot_product * 0.5

    let pan = 0.5 + 0.5 * rm.vector3_dot_product(normalized_direction, right)

    rl.set_sound_volume(sound, attenuation)
    rl.set_sound_pan(sound, pan)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - sound positioning")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let sound = rl.load_sound("coin.wav")
    defer rl.unload_sound(sound)

    var camera = rl.Camera(
        position = rl.Vector3(x = 0.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)

        let th = rl.get_time()
        let sphere_pos = rl.Vector3(
            x = 5.0 * float<-math.cos(th),
            y = 0.0,
            z = 5.0 * float<-math.sin(th)
        )

        set_sound_position(camera, sound, sphere_pos, 1.0)
        if not rl.is_sound_playing(sound):
            rl.play_sound(sound)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(camera)
        rl.draw_grid(10, 2.0)
        rl.draw_sphere(sphere_pos, 0.5, rl.RED)
        rl.end_mode_3d()
        rl.end_drawing()

    return 0
