module examples.raylib.textures.textures_framebuffer_rendering

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const split_width: i32 = screen_width / 2
const window_title: cstr = c"raylib [textures] example - framebuffer rendering"
const observer_view_text: cstr = c"Observer View"
const observer_controls_move_text: cstr = c"WASD + Mouse to Move"
const observer_controls_zoom_text: cstr = c"Scroll to Zoom"
const observer_controls_reset_text: cstr = c"R to Reset Observer Target"
const subject_view_text: cstr = c"Subject View"
const near_plane: f32 = 0.05
const capture_size: f32 = 128.0

def draw_camera_prism(camera: rl.Camera3D, aspect: f32, color: rl.Color) -> void:
    let length = camera.position.distance(camera.target)
    let plane_ndc = array[rl.Vector3, 4](
        rl.Vector3(x = -1.0, y = -1.0, z = 1.0),
        rl.Vector3(x = 1.0, y = -1.0, z = 1.0),
        rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        rl.Vector3(x = -1.0, y = 1.0, z = 1.0),
    )
    let view = rl.GetCameraMatrix(camera)
    let proj = rm.Matrix.perspective(camera.fovy * rm.deg2rad, aspect, near_plane, length)
    let inverse_view_proj = view.multiply(proj).invert()
    var corners = zero[array[rl.Vector3, 4]]()

    for index in range(0, 4):
        let point = plane_ndc[index]
        let x = point.x
        let y = point.y
        let z = point.z
        let vx = inverse_view_proj.m0 * x + inverse_view_proj.m4 * y + inverse_view_proj.m8 * z + inverse_view_proj.m12
        let vy = inverse_view_proj.m1 * x + inverse_view_proj.m5 * y + inverse_view_proj.m9 * z + inverse_view_proj.m13
        let vz = inverse_view_proj.m2 * x + inverse_view_proj.m6 * y + inverse_view_proj.m10 * z + inverse_view_proj.m14
        let vw = inverse_view_proj.m3 * x + inverse_view_proj.m7 * y + inverse_view_proj.m11 * z + inverse_view_proj.m15
        corners[index] = rl.Vector3(x = vx / vw, y = vy / vw, z = vz / vw)

    rl.DrawLine3D(corners[0], corners[1], color)
    rl.DrawLine3D(corners[1], corners[2], color)
    rl.DrawLine3D(corners[2], corners[3], color)
    rl.DrawLine3D(corners[3], corners[0], color)

    for index in range(0, 4):
        rl.DrawLine3D(camera.position, corners[index], color)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var subject_camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    var observer_camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let observer_target = rl.LoadRenderTexture(split_width, screen_height)
    let observer_source = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-observer_target.texture.width, height = -f32<-observer_target.texture.height)
    let observer_dest = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-split_width, height = f32<-screen_height)

    let subject_target = rl.LoadRenderTexture(split_width, screen_height)
    let subject_source = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-subject_target.texture.width, height = -f32<-subject_target.texture.height)
    let subject_dest = rl.Rectangle(x = f32<-split_width, y = 0.0, width = f32<-split_width, height = f32<-screen_height)
    let texture_aspect_ratio = f32<-subject_target.texture.width / f32<-subject_target.texture.height
    let crop_source = rl.Rectangle(
        x = (f32<-subject_target.texture.width - capture_size) / 2.0,
        y = (f32<-subject_target.texture.height - capture_size) / 2.0,
        width = capture_size,
        height = -capture_size,
    )
    let crop_dest = rl.Rectangle(x = f32<-split_width + 20.0, y = 20.0, width = capture_size, height = capture_size)

    defer:
        rl.UnloadRenderTexture(subject_target)
        rl.UnloadRenderTexture(observer_target)

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(observer_camera)), rl.CameraMode.CAMERA_FREE)
        rl.UpdateCamera(raw(addr(subject_camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            observer_camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

        rl.BeginTextureMode(observer_target)
        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(observer_camera)
        rl.DrawGrid(10, 1.0)
        rl.DrawCube(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.GOLD)
        rl.DrawCubeWires(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.PINK)
        draw_camera_prism(subject_camera, texture_aspect_ratio, rl.GREEN)
        rl.EndMode3D()
        rl.DrawText(observer_view_text, 10, observer_target.texture.height - 30, 20, rl.BLACK)
        rl.DrawText(observer_controls_move_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(observer_controls_zoom_text, 10, 30, 20, rl.DARKGRAY)
        rl.DrawText(observer_controls_reset_text, 10, 50, 20, rl.DARKGRAY)
        rl.EndTextureMode()

        rl.BeginTextureMode(subject_target)
        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(subject_camera)
        rl.DrawCube(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.GOLD)
        rl.DrawCubeWires(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.PINK)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.DrawRectangleLines(
            i32<-((f32<-subject_target.texture.width - capture_size) / 2.0),
            i32<-((f32<-subject_target.texture.height - capture_size) / 2.0),
            i32<-capture_size,
            i32<-capture_size,
            rl.GREEN,
        )
        rl.DrawText(subject_view_text, 10, subject_target.texture.height - 30, 20, rl.BLACK)
        rl.EndTextureMode()

        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)
        rl.DrawTexturePro(observer_target.texture, observer_source, observer_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.DrawTexturePro(subject_target.texture, subject_source, subject_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.DrawTexturePro(subject_target.texture, crop_source, crop_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.DrawRectangleLinesEx(crop_dest, 2.0, rl.BLACK)
        rl.DrawLine(split_width, 0, split_width, screen_height, rl.BLACK)
        rl.EndDrawing()

    return 0
