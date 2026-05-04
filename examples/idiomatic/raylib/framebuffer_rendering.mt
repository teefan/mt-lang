module examples.idiomatic.raylib.framebuffer_rendering

import std.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const split_width: i32 = screen_width / 2
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
    let view = rl.get_camera_matrix(camera)
    let proj = rm.Matrix.perspective(camera.fovy * rm.deg2rad, aspect, near_plane, length)
    let inverse_view_proj = view.multiply(proj).invert()
    var corners = zero[array[rl.Vector3, 4]]()

    for index in 0..4:
        let point = plane_ndc[index]
        let x = point.x
        let y = point.y
        let z = point.z
        let vx = inverse_view_proj.m0 * x + inverse_view_proj.m4 * y + inverse_view_proj.m8 * z + inverse_view_proj.m12
        let vy = inverse_view_proj.m1 * x + inverse_view_proj.m5 * y + inverse_view_proj.m9 * z + inverse_view_proj.m13
        let vz = inverse_view_proj.m2 * x + inverse_view_proj.m6 * y + inverse_view_proj.m10 * z + inverse_view_proj.m14
        let vw = inverse_view_proj.m3 * x + inverse_view_proj.m7 * y + inverse_view_proj.m11 * z + inverse_view_proj.m15
        corners[index] = rl.Vector3(x = vx / vw, y = vy / vw, z = vz / vw)

    rl.draw_line_3d(corners[0], corners[1], color)
    rl.draw_line_3d(corners[1], corners[2], color)
    rl.draw_line_3d(corners[2], corners[3], color)
    rl.draw_line_3d(corners[3], corners[0], color)

    for index in 0..4:
        rl.draw_line_3d(camera.position, corners[index], color)


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Framebuffer Rendering")
    defer rl.close_window()

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

    let observer_target = rl.load_render_texture(split_width, screen_height)
    let observer_source = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-observer_target.texture.width, height = -f32<-observer_target.texture.height)
    let observer_dest = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-split_width, height = f32<-screen_height)

    let subject_target = rl.load_render_texture(split_width, screen_height)
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
        rl.unload_render_texture(subject_target)
        rl.unload_render_texture(observer_target)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(inout observer_camera, rl.CameraMode.CAMERA_FREE)
        rl.update_camera(inout subject_camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            observer_camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

        rl.begin_texture_mode(observer_target)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(observer_camera)
        rl.draw_grid(10, 1.0)
        rl.draw_cube(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.GOLD)
        rl.draw_cube_wires(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.PINK)
        draw_camera_prism(subject_camera, texture_aspect_ratio, rl.GREEN)
        rl.end_mode_3d()
        rl.draw_text("Observer View", 10, observer_target.texture.height - 30, 20, rl.BLACK)
        rl.draw_text("WASD + Mouse to Move", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("Scroll to Zoom", 10, 30, 20, rl.DARKGRAY)
        rl.draw_text("R to Reset Observer Target", 10, 50, 20, rl.DARKGRAY)
        rl.end_texture_mode()

        rl.begin_texture_mode(subject_target)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(subject_camera)
        rl.draw_cube(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.GOLD)
        rl.draw_cube_wires(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 2.0, 2.0, rl.PINK)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()
        rl.draw_rectangle_lines(
            i32<-((f32<-subject_target.texture.width - capture_size) / 2.0),
            i32<-((f32<-subject_target.texture.height - capture_size) / 2.0),
            i32<-capture_size,
            i32<-capture_size,
            rl.GREEN,
        )
        rl.draw_text("Subject View", 10, subject_target.texture.height - 30, 20, rl.BLACK)
        rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        rl.draw_texture_pro(observer_target.texture, observer_source, observer_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_texture_pro(subject_target.texture, subject_source, subject_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_texture_pro(subject_target.texture, crop_source, crop_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_rectangle_lines_ex(crop_dest, 2.0, rl.BLACK)
        rl.draw_line(split_width, 0, split_width, screen_height, rl.BLACK)

    return 0
