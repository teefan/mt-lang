module examples.raylib.models.models_mesh_generation

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const num_models: i32 = 9
const window_title: cstr = c"raylib [models] example - mesh generation"
const cycle_prompt: cstr = c"MOUSE LEFT BUTTON to CYCLE PROCEDURAL MODELS"


def model_label(model_index: i32) -> cstr:
    if model_index == 0:
        return c"PLANE"
    if model_index == 1:
        return c"CUBE"
    if model_index == 2:
        return c"SPHERE"
    if model_index == 3:
        return c"HEMISPHERE"
    if model_index == 4:
        return c"CYLINDER"
    if model_index == 5:
        return c"TORUS"
    if model_index == 6:
        return c"KNOT"
    if model_index == 7:
        return c"POLY"
    if model_index == 8:
        return c"Custom (triangle)"
    return c""


def model_label_x(model_index: i32) -> i32:
    if model_index == 3:
        return 640
    if model_index == 8:
        return 580
    return 680


def custom_mesh() -> rl.Mesh:
    var mesh = zero[rl.Mesh]()
    mesh.triangleCount = 1
    mesh.vertexCount = mesh.triangleCount * 3

    unsafe:
        let vertex_count = u32<-(mesh.vertexCount * 3)
        let texcoord_count = u32<-(mesh.vertexCount * 2)

        mesh.vertices = ptr[f32]<-rl.MemAlloc(vertex_count * u32<-sizeof(f32))
        mesh.texcoords = ptr[f32]<-rl.MemAlloc(texcoord_count * u32<-sizeof(f32))
        mesh.normals = ptr[f32]<-rl.MemAlloc(vertex_count * u32<-sizeof(f32))

        mesh.vertices[0] = 0.0
        mesh.vertices[1] = 0.0
        mesh.vertices[2] = 0.0
        mesh.normals[0] = 0.0
        mesh.normals[1] = 1.0
        mesh.normals[2] = 0.0
        mesh.texcoords[0] = 0.0
        mesh.texcoords[1] = 0.0

        mesh.vertices[3] = 1.0
        mesh.vertices[4] = 0.0
        mesh.vertices[5] = 2.0
        mesh.normals[3] = 0.0
        mesh.normals[4] = 1.0
        mesh.normals[5] = 0.0
        mesh.texcoords[2] = 0.5
        mesh.texcoords[3] = 1.0

        mesh.vertices[6] = 2.0
        mesh.vertices[7] = 0.0
        mesh.vertices[8] = 0.0
        mesh.normals[6] = 0.0
        mesh.normals[7] = 1.0
        mesh.normals[8] = 0.0
        mesh.texcoords[4] = 1.0
        mesh.texcoords[5] = 0.0

    rl.UploadMesh(ptr_of(ref_of(mesh)), false)
    return mesh


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let checked = rl.GenImageChecked(2, 2, 1, 1, rl.RED, rl.GREEN)
    let texture = rl.LoadTextureFromImage(checked)
    rl.UnloadImage(checked)
    defer rl.UnloadTexture(texture)

    var models = zero[array[rl.Model, 9]]()
    models[0] = rl.LoadModelFromMesh(rl.GenMeshPlane(2.0, 2.0, 4, 3))
    models[1] = rl.LoadModelFromMesh(rl.GenMeshCube(2.0, 1.0, 2.0))
    models[2] = rl.LoadModelFromMesh(rl.GenMeshSphere(2.0, 32, 32))
    models[3] = rl.LoadModelFromMesh(rl.GenMeshHemiSphere(2.0, 16, 16))
    models[4] = rl.LoadModelFromMesh(rl.GenMeshCylinder(1.0, 2.0, 16))
    models[5] = rl.LoadModelFromMesh(rl.GenMeshTorus(0.25, 4.0, 16, 32))
    models[6] = rl.LoadModelFromMesh(rl.GenMeshKnot(1.0, 2.0, 16, 128))
    models[7] = rl.LoadModelFromMesh(rl.GenMeshPoly(5, 2.0))
    models[8] = rl.LoadModelFromMesh(custom_mesh())
    defer:
        for index in 0..num_models:
            rl.UnloadModel(models[index])

    for index in 0..num_models:
        rl.SetMaterialTexture(models[index].materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var current_model = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            current_model = (current_model + 1) % num_models

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            current_model += 1
            if current_model >= num_models:
                current_model = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            current_model -= 1
            if current_model < 0:
                current_model = num_models - 1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(models[current_model], position, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawRectangle(30, 400, 310, 30, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(30, 400, 310, 30, rl.Fade(rl.DARKBLUE, 0.5))
        rl.DrawText(cycle_prompt, 40, 410, 10, rl.BLUE)
        rl.DrawText(model_label(current_model), model_label_x(current_model), 10, 20, rl.DARKBLUE)

    return 0
