import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - heightmap rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 18.0, y = 21.0, z = 18.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let image = rl.load_image("heightmap.png")
    defer rl.unload_image(image)
    let texture = rl.load_texture_from_image(image)
    defer rl.unload_texture(texture)

    let model = rl.load_model_from_mesh(rl.gen_mesh_heightmap(image, rl.Vector3(x = 16.0, y = 8.0, z = 16.0)))
    defer rl.unload_model(model)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let map_position = rl.Vector3(x = -8.0, y = 0.0, z = -8.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, map_position, 1.0, rl.RED)
        rl.draw_grid(20, 1.0)
        rl.end_mode_3d()

        rl.draw_texture(texture, SCREEN_WIDTH - texture.width - 20, 20, rl.WHITE)
        rl.draw_rectangle_lines(SCREEN_WIDTH - texture.width - 20, 20, texture.width, texture.height, rl.GREEN)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
