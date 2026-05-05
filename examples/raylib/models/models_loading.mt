module examples.raylib.models.models_loading

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [models] example - loading"
const castle_model_path: cstr = c"../resources/models/obj/castle.obj"
const castle_texture_path: cstr = c"../resources/models/obj/castle_diffuse.png"
const drag_drop_text: cstr = c"Drag & drop model to load mesh/texture."
const selected_text: cstr = c"MODEL SELECTED"
const castle_credit: cstr = c"(c) Castle 3D model by Alberto Cano"


def is_supported_model_path(path: cstr) -> bool:
    return rl.IsFileExtension(path, c".obj") or rl.IsFileExtension(path, c".gltf") or rl.IsFileExtension(path, c".glb") or rl.IsFileExtension(path, c".vox") or rl.IsFileExtension(path, c".iqm") or rl.IsFileExtension(path, c".m3d")


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 50.0, y = 50.0, z = 50.0),
        target = rl.Vector3(x = 0.0, y = 12.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(castle_model_path)
    var texture = rl.LoadTexture(castle_texture_path)
    rl.SetMaterialTexture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var bounds = rl.GetModelBoundingBox(model)
    var selected = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()

            if dropped_files.count == 1:
                unsafe:
                    let dropped_path = cstr<-read(dropped_files.paths)

                    if is_supported_model_path(dropped_path):
                        rl.UnloadModel(model)
                        model = rl.LoadModel(dropped_path)
                        rl.SetMaterialTexture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

                        bounds = rl.GetModelBoundingBox(model)
                        camera.position.x = bounds.max.x + 10.0
                        camera.position.y = bounds.max.y + 10.0
                        camera.position.z = bounds.max.z + 10.0
                    elif rl.IsFileExtension(dropped_path, c".png"):
                        rl.UnloadTexture(texture)
                        texture = rl.LoadTexture(dropped_path)
                        rl.SetMaterialTexture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

            rl.UnloadDroppedFiles(dropped_files)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if rl.GetRayCollisionBox(rl.GetScreenToWorldRay(rl.GetMousePosition(), camera), bounds).hit:
                selected = not selected
            else:
                selected = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawModel(model, position, 1.0, rl.WHITE)
        rl.DrawGrid(20, 10.0)
        if selected:
            rl.DrawBoundingBox(bounds, rl.GREEN)

        rl.EndMode3D()

        rl.DrawText(drag_drop_text, 10, rl.GetScreenHeight() - 20, 10, rl.DARKGRAY)
        if selected:
            rl.DrawText(selected_text, rl.GetScreenWidth() - 110, 10, 10, rl.GREEN)
        rl.DrawText(castle_credit, screen_width - 200, screen_height - 20, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    rl.UnloadTexture(texture)
    rl.UnloadModel(model)

    return 0
