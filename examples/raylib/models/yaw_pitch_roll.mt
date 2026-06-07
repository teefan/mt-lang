import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const DEG_TO_RAD: float = 0.0174532925


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - yaw pitch roll")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 50.0, z = -120.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 30.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var model = rl.load_model("models/obj/plane.obj")
    defer rl.unload_model(model)
    let texture = rl.load_texture("models/obj/plane_diffuse.png")
    defer rl.unload_texture(texture)
    rl.set_texture_wrap(texture, int<-rl.TextureWrap.TEXTURE_WRAP_REPEAT)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var pitch = float<-0.0
    var roll = float<-0.0
    var yaw = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            pitch += 0.6
        else if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            pitch -= 0.6
        else:
            if pitch > 0.3:
                pitch -= 0.3
            else if pitch < -0.3:
                pitch += 0.3

        if rl.is_key_down(rl.KeyboardKey.KEY_S):
            yaw -= 1.0
        else if rl.is_key_down(rl.KeyboardKey.KEY_A):
            yaw += 1.0
        else:
            if yaw > 0.0:
                yaw -= 0.5
            else if yaw < 0.0:
                yaw += 0.5

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            roll -= 1.0
        else if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            roll += 1.0
        else:
            if roll > 0.0:
                roll -= 0.5
            else if roll < 0.0:
                roll += 0.5

        model.transform = rm.matrix_rotate_xyz(
            rl.Vector3(
                x = DEG_TO_RAD * pitch,
                y = DEG_TO_RAD * yaw,
                z = DEG_TO_RAD * roll
            )
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = -8.0, z = 0.0), 1.0, rl.WHITE)
        rl.draw_grid(10, 10.0)
        rl.end_mode_3d()

        rl.draw_rectangle(30, 370, 260, 70, rl.fade(rl.GREEN, 0.5))
        rl.draw_rectangle_lines(30, 370, 260, 70, rl.fade(rl.DARKGREEN, 0.5))
        rl.draw_text("Pitch controlled with: KEY_UP / KEY_DOWN", 40, 380, 10, rl.DARKGRAY)
        rl.draw_text("Roll controlled with: KEY_LEFT / KEY_RIGHT", 40, 400, 10, rl.DARKGRAY)
        rl.draw_text("Yaw controlled with: KEY_A / KEY_S", 40, 420, 10, rl.DARKGRAY)
        rl.draw_text(
            "(c) WWI Plane Model created by GiaHanLam",
            SCREEN_WIDTH - 240,
            SCREEN_HEIGHT - 20,
            10,
            rl.DARKGRAY
        )
        rl.end_drawing()

    return 0
