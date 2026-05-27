import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - directional billboard")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 1.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let skillbot = rl.load_texture("skillbot.png")
    defer rl.unload_texture(skillbot)

    var anim_timer = float<-0.0
    var anim = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        anim_timer += rl.get_frame_time()
        if anim_timer > 0.5:
            anim_timer = 0.0
            anim += 1
        if anim >= 4:
            anim = 0

        var dir = float<-math.floor(double<-(((rm.vector2_angle(rl.Vector2(x = 2.0, y = 0.0), rl.Vector2(x = camera.position.x, y = camera.position.z)) / rl.PI) * 4.0) + 0.25))
        if dir < 0.0:
            dir = 8.0 - float<-math.abs(double<-dir)

        let source = rl.Rectangle(x = float<-(anim * 24), y = dir * 24.0, width = 24.0, height = 24.0)
        let animation_text = rl.text_format("animation: %d", anim)
        let direction_text = rl.text_format("direction frame: %.0f", dir)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_grid(10, 1.0)
        rl.draw_billboard_pro(camera, skillbot, source, rm.vector3_zero(), rl.Vector3(x = 0.0, y = 1.0, z = 0.0), rm.vector2_one(), rl.Vector2(x = 0.5, y = 0.0), 0.0, rl.WHITE)
        rl.end_mode_3d()

        rl.draw_text(animation_text, 10, 10, 20, rl.DARKGRAY)
        rl.draw_text(direction_text, 10, 40, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
