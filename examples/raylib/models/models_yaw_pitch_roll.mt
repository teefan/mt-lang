module examples.raylib.models.models_yaw_pitch_roll

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [models] example - yaw pitch roll"
const model_path: cstr = c"../resources/models/obj/plane.obj"
const texture_path: cstr = c"../resources/models/obj/plane_diffuse.png"
const pitch_controls_text: cstr = c"Pitch controlled with: KEY_UP / KEY_DOWN"
const roll_controls_text: cstr = c"Roll controlled with: KEY_LEFT / KEY_RIGHT"
const yaw_controls_text: cstr = c"Yaw controlled with: KEY_A / KEY_S"
const credit_text: cstr = c"(c) WWI Plane Model created by GiaHanLam"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 50.0, z = -120.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 30.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetTextureWrap(texture, rl.TextureWrap.TEXTURE_WRAP_REPEAT)
    rl.SetMaterialTexture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var pitch: float = 0.0
    var roll: float = 0.0
    var yaw: float = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            pitch += 0.6
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            pitch -= 0.6
        else:
            if pitch > 0.3:
                pitch -= 0.3
            elif pitch < -0.3:
                pitch += 0.3

        if rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            yaw -= 1.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            yaw += 1.0
        else:
            if yaw > 0.0:
                yaw -= 0.5
            elif yaw < 0.0:
                yaw += 0.5

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            roll -= 1.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            roll += 1.0
        else:
            if roll > 0.0:
                roll -= 0.5
            elif roll < 0.0:
                roll += 0.5

        model.transform = rm.Matrix.rotate_xyz(
            rl.Vector3(
                x = rm.deg2rad * pitch,
                y = rm.deg2rad * yaw,
                z = rm.deg2rad * roll,
            ),
        )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModel(model, rl.Vector3(x = 0.0, y = -8.0, z = 0.0), 1.0, rl.WHITE)
        rl.DrawGrid(10, 10.0)
        rl.EndMode3D()

        rl.DrawRectangle(30, 370, 260, 70, rl.Fade(rl.GREEN, 0.5))
        rl.DrawRectangleLines(30, 370, 260, 70, rl.Fade(rl.DARKGREEN, 0.5))
        rl.DrawText(pitch_controls_text, 40, 380, 10, rl.DARKGRAY)
        rl.DrawText(roll_controls_text, 40, 400, 10, rl.DARKGRAY)
        rl.DrawText(yaw_controls_text, 40, 420, 10, rl.DARKGRAY)
        rl.DrawText(credit_text, screen_width - 240, screen_height - 20, 10, rl.DARKGRAY)

    return 0
