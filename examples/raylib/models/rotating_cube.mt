import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - rotating cube")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 3.0, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let model = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(model)

    let image = rl.load_image("cubicmap_atlas.png")
    defer rl.unload_image(image)
    let crop = rl.image_from_image(
        image,
        rl.Rectangle(
            x = 0.0,
            y = float<-image.height / 2.0,
            width = float<-image.width / 2.0,
            height = float<-image.height / 2.0
        )
    )
    defer rl.unload_image(crop)
    let texture = rl.load_texture_from_image(crop)
    defer rl.unload_texture(texture)

    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var rotation = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 1.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model_ex(
            model,
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.5, y = 1.0, z = 0.0),
            rotation,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE
        )
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
