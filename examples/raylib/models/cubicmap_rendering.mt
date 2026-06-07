import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - cubicmap rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 16.0, y = 14.0, z = 16.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let image = rl.load_image("cubicmap.png")
    defer rl.unload_image(image)
    let cubicmap = rl.load_texture_from_image(image)
    defer rl.unload_texture(cubicmap)

    let model = rl.load_model_from_mesh(rl.gen_mesh_cubicmap(image, rl.Vector3(x = 1.0, y = 1.0, z = 1.0)))
    defer rl.unload_model(model)
    let texture = rl.load_texture("cubicmap_atlas.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let map_position = rl.Vector3(x = -16.0, y = 0.0, z = -8.0)
    var pause = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            pause = not pause

        if not pause:
            rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, map_position, 1.0, rl.WHITE)
        rl.end_mode_3d()

        rl.draw_texture_ex(
            cubicmap,
            rl.Vector2(x = float<-(SCREEN_WIDTH - cubicmap.width * 4 - 20), y = 20.0),
            0.0,
            4.0,
            rl.WHITE
        )
        rl.draw_rectangle_lines(
            SCREEN_WIDTH - cubicmap.width * 4 - 20,
            20,
            cubicmap.width * 4,
            cubicmap.height * 4,
            rl.GREEN
        )
        rl.draw_text("cubicmap image used to", 658, 90, 10, rl.GRAY)
        rl.draw_text("generate map 3d model", 658, 104, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
