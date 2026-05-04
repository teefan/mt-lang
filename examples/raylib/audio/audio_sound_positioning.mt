module examples.raylib.audio.audio_sound_positioning

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const sound_path: cstr = c"../resources/coin.wav"
const window_title: cstr = c"raylib [audio] example - sound positioning"


def set_sound_position(listener: rl.Camera3D, sound: rl.Sound, position: rl.Vector3, max_dist: f32) -> void:
    let direction = position.subtract(listener.position)
    let distance = direction.length()

    var attenuation = 1.0 / (1.0 + distance / max_dist)
    attenuation = rm.clamp(attenuation, 0.0, 1.0)

    let normalized_direction = direction.normalize()
    let forward = listener.target.subtract(listener.position).normalize()
    let right = listener.up.cross(forward).normalize()

    let dot_product = forward.dot(normalized_direction)
    if dot_product < 0.0:
        attenuation *= 1.0 + dot_product * 0.5

    let pan = 0.5 + 0.5 * normalized_direction.dot(right)

    rl.SetSoundVolume(sound, attenuation)
    rl.SetSoundPan(sound, pan)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let sound = rl.LoadSound(sound_path)
    defer rl.UnloadSound(sound)

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FREE)

        let th = f32<-rl.GetTime()
        let sphere_pos = rl.Vector3(
            x = 5.0 * rm.cos(th),
            y = 0.0,
            z = 5.0 * rm.sin(th),
        )

        set_sound_position(camera, sound, sphere_pos, 1.0)

        if not rl.IsSoundPlaying(sound):
            rl.PlaySound(sound)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawGrid(10, 2.0)
        rl.DrawSphere(sphere_pos, 0.5, rl.RED)
        rl.EndMode3D()

    return 0
