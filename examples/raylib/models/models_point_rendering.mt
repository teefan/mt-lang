module examples.raylib.models.models_point_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm
import std.c.libm as libm

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_points: i32 = 10000000
const min_points: i32 = 1000
const random_resolution: i32 = 1000000
const pi: f32 = 180.0 * rm.deg2rad
const two_pi: f32 = 360.0 * rm.deg2rad
const window_title: cstr = c"raylib [models] example - point rendering"
const point_count_format: cstr = c"Point Count: %d"
const using_draw_model_points_text: cstr = c"Using: DrawModelPoints()"
const using_draw_point3d_text: cstr = c"Using: DrawPoint3D()"

def random_unit() -> f32:
    return cast[f32](rl.GetRandomValue(0, random_resolution)) / cast[f32](random_resolution)

def gen_mesh_points(num_points: i32) -> rl.Mesh:
    var mesh = zero[rl.Mesh]()
    mesh.triangleCount = 1
    mesh.vertexCount = num_points

    unsafe:
        let vertex_count = cast[u32](num_points * 3)
        let color_count = cast[u32](num_points * 4)

        mesh.vertices = cast[ptr[f32]](rl.MemAlloc(vertex_count * cast[u32](sizeof(f32))))
        mesh.colors = cast[ptr[u8]](rl.MemAlloc(color_count * cast[u32](sizeof(u8))))

        for index in range(0, num_points):
            let theta = pi * random_unit()
            let phi = two_pi * random_unit()
            let radius = 10.0 * random_unit()

            mesh.vertices[index * 3] = radius * libm.sinf(theta) * libm.cosf(phi)
            mesh.vertices[index * 3 + 1] = radius * libm.sinf(theta) * libm.sinf(phi)
            mesh.vertices[index * 3 + 2] = radius * libm.cosf(theta)

            let color = rl.ColorFromHSV(radius * 360.0, 1.0, 1.0)
            mesh.colors[index * 4] = color.r
            mesh.colors[index * 4 + 1] = color.g
            mesh.colors[index * 4 + 2] = color.b
            mesh.colors[index * 4 + 3] = color.a

    rl.UploadMesh(raw(addr(mesh)), false)
    return mesh

def draw_model_points(model: rl.Model, position: rl.Vector3, scale: f32, tint: rl.Color) -> void:
    rlgl.rlEnablePointMode()
    rlgl.rlDisableBackfaceCulling()
    rl.DrawModel(model, position, scale, tint)
    rlgl.rlEnableBackfaceCulling()
    rlgl.rlDisablePointMode()

def mesh_point(mesh: rl.Mesh, index: i32) -> rl.Vector3:
    unsafe:
        return rl.Vector3(
            x = mesh.vertices[index * 3],
            y = mesh.vertices[index * 3 + 1],
            z = mesh.vertices[index * 3 + 2],
        )

def mesh_color(mesh: rl.Mesh, index: i32) -> rl.Color:
    unsafe:
        return rl.Color(
            r = mesh.colors[index * 4],
            g = mesh.colors[index * 4 + 1],
            b = mesh.colors[index * 4 + 2],
            a = mesh.colors[index * 4 + 3],
        )

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 3.0, y = 3.0, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var use_draw_model_points = true
    var num_points_changed = false
    var num_points = 1000

    var mesh = gen_mesh_points(num_points)
    var model = rl.LoadModelFromMesh(mesh)
    defer rl.UnloadModel(model)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            use_draw_model_points = not use_draw_model_points
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            num_points = if num_points * 10 > max_points then max_points else num_points * 10
            num_points_changed = true
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            num_points = if num_points / 10 < min_points then min_points else num_points / 10
            num_points_changed = true

        if num_points_changed:
            rl.UnloadModel(model)
            mesh = gen_mesh_points(num_points)
            model = rl.LoadModelFromMesh(mesh)
            num_points_changed = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.BeginMode3D(camera)
        if use_draw_model_points:
            draw_model_points(model, position, 1.0, rl.WHITE)
        else:
            for index in range(0, num_points):
                rl.DrawPoint3D(mesh_point(mesh, index), mesh_color(mesh, index))

        rl.DrawSphereWires(position, 1.0, 10, 10, rl.YELLOW)
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(point_count_format, num_points), 10, screen_height - 50, 40, rl.WHITE)
        rl.DrawText(c"UP - Increase points", 10, 40, 20, rl.WHITE)
        rl.DrawText(c"DOWN - Decrease points", 10, 70, 20, rl.WHITE)
        rl.DrawText(c"SPACE - Drawing function", 10, 100, 20, rl.WHITE)

        if use_draw_model_points:
            rl.DrawText(using_draw_model_points_text, 10, 130, 20, rl.GREEN)
        else:
            rl.DrawText(using_draw_point3d_text, 10, 130, 20, rl.RED)

        rl.DrawFPS(10, 10)

    return 0
