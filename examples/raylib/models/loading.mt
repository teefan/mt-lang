import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - loading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 50.0, y = 50.0, z = 50.0),
        target = rl.Vector3(x = 0.0, y = 12.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/obj/castle.obj")
    defer rl.unload_model(model)
    var texture = rl.load_texture("models/obj/castle_diffuse.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var bounds = rl.get_model_bounding_box(model)
    var selected = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            if dropped_files.count == uint<-1:
                let dropped_path = unsafe: text.chars_as_str(read(dropped_files.paths))

                if rl.is_file_extension(dropped_path, ".obj") or rl.is_file_extension(dropped_path, ".gltf") or rl.is_file_extension(dropped_path, ".glb") or rl.is_file_extension(dropped_path, ".vox") or rl.is_file_extension(dropped_path, ".iqm") or rl.is_file_extension(dropped_path, ".m3d"):
                    rl.unload_model(model)
                    model = rl.load_model(dropped_path)
                    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)
                    bounds = rl.get_model_bounding_box(model)
                    camera.position.x = bounds.max.x + 10.0
                    camera.position.y = bounds.max.y + 10.0
                    camera.position.z = bounds.max.z + 10.0
                else if rl.is_file_extension(dropped_path, ".png"):
                    rl.unload_texture(texture)
                    texture = rl.load_texture(dropped_path)
                    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
            let collision = rl.get_ray_collision_box(ray, bounds)
            selected = collision.hit

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, position, 1.0, rl.WHITE)
        rl.draw_grid(20, 10.0)
        if selected:
            rl.draw_bounding_box(bounds, rl.GREEN)
        rl.end_mode_3d()

        rl.draw_text("Drag & drop model to load mesh/texture.", 10, rl.get_screen_height() - 20, 10, rl.DARKGRAY)
        if selected:
            rl.draw_text("MODEL SELECTED", rl.get_screen_width() - 110, 10, 10, rl.GREEN)
        rl.draw_text("(c) Castle 3D model by Alberto Cano", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
