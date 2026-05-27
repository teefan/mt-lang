import std.raylib as rl
import std.raymath as math


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SPLIT_WIDTH: int = SCREEN_WIDTH / 2
const CAPTURE_SIZE: float = 128.0
const DEG_TO_RAD: float = rl.PI / 180.0


function draw_camera_prism(camera: rl.Camera3D, aspect: float, color: rl.Color) -> void:
    let length = math.vector3_distance(camera.position, camera.target)
    let plane_ndc = array[rl.Vector3, 4](
        rl.Vector3(x = -1.0, y = -1.0, z = 1.0),
        rl.Vector3(x = 1.0, y = -1.0, z = 1.0),
        rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        rl.Vector3(x = -1.0, y = 1.0, z = 1.0),
    )

    let view = rl.get_camera_matrix(camera)
    let proj = math.matrix_perspective(
        double<-(camera.fovy * DEG_TO_RAD),
        double<-aspect,
        0.05,
        double<-length,
    )
    let view_proj = math.matrix_multiply(view, proj)
    let inverse_view_proj = math.matrix_invert(view_proj)

    var corners: array[rl.Vector3, 4] = zero[array[rl.Vector3, 4]]
    var index = 0
    while index < 4:
        let x = plane_ndc[index].x
        let y = plane_ndc[index].y
        let z = plane_ndc[index].z

        let vx = inverse_view_proj.m0 * x + inverse_view_proj.m4 * y + inverse_view_proj.m8 * z + inverse_view_proj.m12
        let vy = inverse_view_proj.m1 * x + inverse_view_proj.m5 * y + inverse_view_proj.m9 * z + inverse_view_proj.m13
        let vz = inverse_view_proj.m2 * x + inverse_view_proj.m6 * y + inverse_view_proj.m10 * z + inverse_view_proj.m14
        let vw = inverse_view_proj.m3 * x + inverse_view_proj.m7 * y + inverse_view_proj.m11 * z + inverse_view_proj.m15

        corners[index] = rl.Vector3(x = vx / vw, y = vy / vw, z = vz / vw)
        index += 1

    rl.draw_line_3d(corners[0], corners[1], color)
    rl.draw_line_3d(corners[1], corners[2], color)
    rl.draw_line_3d(corners[2], corners[3], color)
    rl.draw_line_3d(corners[3], corners[0], color)

    index = 0
    while index < 4:
        rl.draw_line_3d(camera.position, corners[index], color)
        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - framebuffer rendering")
    defer rl.close_window()

    var subject_camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    var observer_camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let observer_target = rl.load_render_texture(SPLIT_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(observer_target)
    let observer_source = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-observer_target.texture.width,
        height = -float<-observer_target.texture.height,
    )
    let observer_dest = rl.Rectangle(x = 0.0, y = 0.0, width = float<-SPLIT_WIDTH, height = float<-SCREEN_HEIGHT)

    let subject_target = rl.load_render_texture(SPLIT_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(subject_target)
    let subject_source = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-subject_target.texture.width,
        height = -float<-subject_target.texture.height,
    )
    let subject_dest = rl.Rectangle(x = float<-SPLIT_WIDTH, y = 0.0, width = float<-SPLIT_WIDTH, height = float<-SCREEN_HEIGHT)
    let texture_aspect_ratio = float<-subject_target.texture.width / float<-subject_target.texture.height

    let crop_source = rl.Rectangle(
        x = (float<-subject_target.texture.width - CAPTURE_SIZE) / 2.0,
        y = (float<-subject_target.texture.height - CAPTURE_SIZE) / 2.0,
        width = CAPTURE_SIZE,
        height = -CAPTURE_SIZE,
    )
    let crop_dest = rl.Rectangle(x = float<-SPLIT_WIDTH + 20.0, y = 20.0, width = CAPTURE_SIZE, height = CAPTURE_SIZE)

    rl.set_target_fps(60)
    rl.disable_cursor()

    while not rl.window_should_close():
        rl.update_camera(observer_camera, rl.CameraMode.CAMERA_FREE)
        rl.update_camera(subject_camera, rl.CameraMode.CAMERA_ORBITAL)

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
            int<-((float<-subject_target.texture.width - CAPTURE_SIZE) / 2.0),
            int<-((float<-subject_target.texture.height - CAPTURE_SIZE) / 2.0),
            int<-CAPTURE_SIZE,
            int<-CAPTURE_SIZE,
            rl.GREEN,
        )
        rl.draw_text("Subject View", 10, subject_target.texture.height - 30, 20, rl.BLACK)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.draw_texture_pro(observer_target.texture, observer_source, observer_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_texture_pro(subject_target.texture, subject_source, subject_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_texture_pro(subject_target.texture, crop_source, crop_dest, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.draw_rectangle_lines_ex(crop_dest, 2.0, rl.BLACK)
        rl.draw_line(SPLIT_WIDTH, 0, SPLIT_WIDTH, SCREEN_HEIGHT, rl.BLACK)
        rl.end_drawing()

    return 0
