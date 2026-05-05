module examples.raylib.models.models_mesh_picking

import std.c.raylib as rl
import std.raylib.math as mt_math

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [models] example - mesh picking"
const float_max: float = 340282346638528859811704183484516925440.0
const turret_model_path: cstr = c"../resources/models/obj/turret.obj"
const turret_texture_path: cstr = c"../resources/models/obj/turret_diffuse.png"
const toggle_text: cstr = c"Right click mouse to toggle camera controls"
const turret_credit: cstr = c"(c) Turret 3D model by Alberto Cano"


def vector3_barycenter(point: rl.Vector3, a: rl.Vector3, b: rl.Vector3, c: rl.Vector3) -> rl.Vector3:
    let v0 = b.subtract(a)
    let v1 = c.subtract(a)
    let v2 = point.subtract(a)

    let d00 = v0.dot(v0)
    let d01 = v0.dot(v1)
    let d11 = v1.dot(v1)
    let d20 = v2.dot(v0)
    let d21 = v2.dot(v1)
    let denominator = d00 * d11 - d01 * d01

    let v = (d11 * d20 - d01 * d21) / denominator
    let w = (d00 * d21 - d01 * d20) / denominator
    let u = 1.0 - v - w
    return rl.Vector3(x = u, y = v, z = w)


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 20.0, y = 20.0, z = 20.0),
        target = rl.Vector3(x = 0.0, y = 8.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.6, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var ray = zero[rl.Ray]

    let tower = rl.LoadModel(turret_model_path)
    defer rl.UnloadModel(tower)

    let texture = rl.LoadTexture(turret_texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetMaterialTexture(tower.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let tower_pos = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    let tower_bbox = rl.GetModelBoundingBox(tower)

    let g0 = rl.Vector3(x = -50.0, y = 0.0, z = -50.0)
    let g1 = rl.Vector3(x = -50.0, y = 0.0, z = 50.0)
    let g2 = rl.Vector3(x = 50.0, y = 0.0, z = 50.0)
    let g3 = rl.Vector3(x = 50.0, y = 0.0, z = -50.0)

    let ta = rl.Vector3(x = -25.0, y = 0.5, z = 0.0)
    let tb = rl.Vector3(x = -4.0, y = 2.5, z = 1.0)
    let tc = rl.Vector3(x = -8.0, y = 6.5, z = 0.0)

    var bary = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let sp = rl.Vector3(x = -30.0, y = 5.0, z = 5.0)
    let sr: float = 4.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsCursorHidden():
            rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.IsCursorHidden():
                rl.EnableCursor()
            else:
                rl.DisableCursor()

        var collision = zero[rl.RayCollision]
        var hit_object_name: cstr = c"None"
        collision.distance = float_max
        collision.hit = false
        var cursor_color = rl.WHITE

        ray = rl.GetScreenToWorldRay(rl.GetMousePosition(), camera)

        let ground_hit_info = rl.GetRayCollisionQuad(ray, g0, g1, g2, g3)
        if ground_hit_info.hit and ground_hit_info.distance < collision.distance:
            collision = ground_hit_info
            cursor_color = rl.GREEN
            hit_object_name = c"Ground"

        let tri_hit_info = rl.GetRayCollisionTriangle(ray, ta, tb, tc)
        if tri_hit_info.hit and tri_hit_info.distance < collision.distance:
            collision = tri_hit_info
            cursor_color = rl.PURPLE
            hit_object_name = c"Triangle"
            bary = vector3_barycenter(collision.point, ta, tb, tc)

        let sphere_hit_info = rl.GetRayCollisionSphere(ray, sp, sr)
        if sphere_hit_info.hit and sphere_hit_info.distance < collision.distance:
            collision = sphere_hit_info
            cursor_color = rl.ORANGE
            hit_object_name = c"Sphere"

        let box_hit_info = rl.GetRayCollisionBox(ray, tower_bbox)
        if box_hit_info.hit and box_hit_info.distance < collision.distance:
            collision = box_hit_info
            cursor_color = rl.ORANGE
            hit_object_name = c"Box"

            var mesh_hit_info = zero[rl.RayCollision]
            for mesh_index in 0..tower.meshCount:
                unsafe:
                    mesh_hit_info = rl.GetRayCollisionMesh(ray, tower.meshes[mesh_index], tower.transform)

                if mesh_hit_info.hit:
                    if not collision.hit or collision.distance > mesh_hit_info.distance:
                        collision = mesh_hit_info
                    break

            if mesh_hit_info.hit:
                collision = mesh_hit_info
                cursor_color = rl.ORANGE
                hit_object_name = c"Mesh"

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawModel(tower, tower_pos, 1.0, rl.WHITE)

        rl.DrawLine3D(ta, tb, rl.PURPLE)
        rl.DrawLine3D(tb, tc, rl.PURPLE)
        rl.DrawLine3D(tc, ta, rl.PURPLE)

        rl.DrawSphereWires(sp, sr, 8, 8, rl.PURPLE)

        if box_hit_info.hit:
            rl.DrawBoundingBox(tower_bbox, rl.LIME)

        if collision.hit:
            rl.DrawCube(collision.point, 0.3, 0.3, 0.3, cursor_color)
            rl.DrawCubeWires(collision.point, 0.3, 0.3, 0.3, rl.RED)

            let normal_end = rl.Vector3(
                x = collision.point.x + collision.normal.x,
                y = collision.point.y + collision.normal.y,
                z = collision.point.z + collision.normal.z,
            )
            rl.DrawLine3D(collision.point, normal_end, rl.RED)

        rl.DrawRay(ray, rl.MAROON)
        rl.DrawGrid(10, 10.0)

        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(c"Hit Object: %s", hit_object_name), 10, 50, 10, rl.BLACK)

        if collision.hit:
            let ypos = 70
            rl.DrawText(rl.TextFormat(c"Distance: %3.2f", collision.distance), 10, ypos, 10, rl.BLACK)
            rl.DrawText(rl.TextFormat(c"Hit Pos: %3.2f %3.2f %3.2f", collision.point.x, collision.point.y, collision.point.z), 10, ypos + 15, 10, rl.BLACK)
            rl.DrawText(rl.TextFormat(c"Hit Norm: %3.2f %3.2f %3.2f", collision.normal.x, collision.normal.y, collision.normal.z), 10, ypos + 30, 10, rl.BLACK)

            if tri_hit_info.hit and rl.TextIsEqual(hit_object_name, c"Triangle"):
                rl.DrawText(rl.TextFormat(c"Barycenter: %3.2f %3.2f %3.2f", bary.x, bary.y, bary.z), 10, ypos + 45, 10, rl.BLACK)

        rl.DrawText(toggle_text, 10, 430, 10, rl.GRAY)
        rl.DrawText(turret_credit, screen_width - 200, screen_height - 20, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0
