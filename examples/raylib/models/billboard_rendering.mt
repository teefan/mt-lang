import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - billboard rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 4.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let bill = rl.load_texture("billboard.png")
    defer rl.unload_texture(bill)

    let static_position = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
    let rotating_position = rl.Vector3(x = 1.0, y = 2.0, z = 1.0)
    let source = rl.Rectangle(x = 0.0, y = 0.0, width = float<-bill.width, height = float<-bill.height)
    let billboard_up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let size = rl.Vector2(x = source.width / source.height, y = 1.0)
    let origin = rm.vector2_scale(size, 0.5)
    var rotation = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        rotation += 0.4
        let distance_static = rm.vector3_distance(camera.position, static_position)
        let distance_rotating = rm.vector3_distance(camera.position, rotating_position)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_grid(10, 1.0)

        if distance_static > distance_rotating:
            rl.draw_billboard(camera, bill, static_position, 2.0, rl.WHITE)
            rl.draw_billboard_pro(
                camera,
                bill,
                source,
                rotating_position,
                billboard_up,
                size,
                origin,
                rotation,
                rl.WHITE
            )
        else:
            rl.draw_billboard_pro(
                camera,
                bill,
                source,
                rotating_position,
                billboard_up,
                size,
                origin,
                rotation,
                rl.WHITE
            )
            rl.draw_billboard(camera, bill, static_position, 2.0, rl.WHITE)

        rl.end_mode_3d()
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
