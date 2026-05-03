module examples.raylib.models.models_decals

import std.c.libm as libm
import std.c.raylib as rl
import std.raylib.math as rm
import std.span as sp

struct MeshBuilder:
    vertexCount: i32
    vertexCapacity: i32
    vertices: ptr[rl.Vector3]
    uvs: ptr[rl.Vector2]
    hasUvs: bool

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_decals: i32 = 256
const float_max: f32 = 340282346638528859811704183484516925440.0
const character_model_path: cstr = c"../resources/models/obj/character.obj"
const character_texture_path: cstr = c"../resources/models/obj/character_diffuse.png"
const decal_texture_path: cstr = c"../resources/raylib_logo.png"
const vertices_text: cstr = c"Vertices"
const triangles_text: cstr = c"Triangles"
const main_model_text: cstr = c"Main model"
const total_text: cstr = c"TOTAL"
const hold_camera_text: cstr = c"Hold RMB to move camera"
const credit_text: cstr = c"(c) Character model and texture from kenney.nl"
const clear_decals_text: cstr = c"Clear Decals"
const hide_model_text: cstr = c"Hide Model"
const show_model_text: cstr = c"Show Model"
const decal_label_format: cstr = c"Decal #%d"
const count_format: cstr = c"%d"
const ellipsis_text: cstr = c"..."
const window_title: cstr = c"raylib [models] example - decals"

def model_mesh(model: rl.Model, index: i32) -> rl.Mesh:
    unsafe:
        return model.meshes[index]

def material_map(material: rl.Material, index: i32) -> rl.MaterialMap:
    unsafe:
        return material.maps[index]

def alloc_vector3(count: i32) -> ptr[rl.Vector3]:
    unsafe:
        return ptr[rl.Vector3]<-rl.MemAlloc(u32<-count * u32<-sizeof(rl.Vector3))

def alloc_vector2(count: i32) -> ptr[rl.Vector2]:
    unsafe:
        return ptr[rl.Vector2]<-rl.MemAlloc(u32<-count * u32<-sizeof(rl.Vector2))

def alloc_f32(count: i32) -> ptr[f32]:
    unsafe:
        return ptr[f32]<-rl.MemAlloc(u32<-count * u32<-sizeof(f32))

def mesh_has_indices(mesh: rl.Mesh) -> bool:
    unsafe:
        return mesh.indices != null

def mesh_vertex(mesh: rl.Mesh, index: i32) -> rl.Vector3:
    unsafe:
        return rl.Vector3(
            x = mesh.vertices[index * 3],
            y = mesh.vertices[index * 3 + 1],
            z = mesh.vertices[index * 3 + 2],
        )

def mesh_index(mesh: rl.Mesh, index: i32) -> i32:
    let indices = mesh.indices
    if indices != null:
        unsafe:
            return i32<-indices[index]

    panic("mesh indices missing")

def triangle_vertices(v0: rl.Vector3, v1: rl.Vector3, v2: rl.Vector3) -> array[rl.Vector3, 3]:
    var vertices = zero[array[rl.Vector3, 3]]()
    vertices[0] = v0
    vertices[1] = v1
    vertices[2] = v2
    return vertices

def mesh_triangle(mesh: rl.Mesh, triangle_index: i32) -> array[rl.Vector3, 3]:
    if not mesh_has_indices(mesh):
        return triangle_vertices(
            mesh_vertex(mesh, triangle_index * 3),
            mesh_vertex(mesh, triangle_index * 3 + 1),
            mesh_vertex(mesh, triangle_index * 3 + 2),
        )

    return triangle_vertices(
        mesh_vertex(mesh, mesh_index(mesh, triangle_index * 3)),
        mesh_vertex(mesh, mesh_index(mesh, triangle_index * 3 + 1)),
        mesh_vertex(mesh, mesh_index(mesh, triangle_index * 3 + 2)),
    )

def add_triangle_to_mesh_builder(mb: ref[MeshBuilder], vertices: array[rl.Vector3, 3]) -> void:
    if mb.vertexCapacity <= mb.vertexCount + 3:
        let new_vertex_capacity = (1 + mb.vertexCapacity / 256) * 256

        let new_vertices = alloc_vector3(new_vertex_capacity)

        if mb.vertexCapacity > 0:
            let old_vertices = sp.from_ptr[rl.Vector3](mb.vertices, usize<-mb.vertexCount)
            var new_vertex_view = sp.from_ptr[rl.Vector3](new_vertices, usize<-mb.vertexCount)
            for index in range(0, mb.vertexCount):
                new_vertex_view[index] = old_vertices[index]

            rl.MemFree(mb.vertices)

        mb.vertices = new_vertices
        mb.vertexCapacity = new_vertex_capacity

    let start = mb.vertexCount
    mb.vertexCount += 3

    var vertex_view = sp.from_ptr[rl.Vector3](mb.vertices, usize<-mb.vertexCount)
    for index in range(0, 3):
        vertex_view[start + index] = vertices[index]

def free_mesh_builder(mb: ref[MeshBuilder]) -> void:
    if mb.vertexCapacity > 0:
        rl.MemFree(mb.vertices)
    if mb.hasUvs:
        rl.MemFree(mb.uvs)
    read(mb) = zero[MeshBuilder]()

def build_mesh(mb: ref[MeshBuilder]) -> rl.Mesh:
    var out_mesh = zero[rl.Mesh]()
    out_mesh.vertexCount = mb.vertexCount
    out_mesh.triangleCount = mb.vertexCount / 3

    out_mesh.vertices = alloc_f32(out_mesh.vertexCount * 3)
    if mb.hasUvs:
        out_mesh.texcoords = alloc_f32(out_mesh.vertexCount * 2)

    let vertices = sp.from_ptr[rl.Vector3](mb.vertices, usize<-mb.vertexCount)
    let uvs = if mb.hasUvs: sp.from_ptr[rl.Vector2](mb.uvs, usize<-mb.vertexCount) else: sp.empty[rl.Vector2]()

    unsafe:
        for index in range(0, mb.vertexCount):
            out_mesh.vertices[index * 3] = vertices[index].x
            out_mesh.vertices[index * 3 + 1] = vertices[index].y
            out_mesh.vertices[index * 3 + 2] = vertices[index].z

            if mb.hasUvs:
                out_mesh.texcoords[index * 2] = uvs[index].x
                out_mesh.texcoords[index * 2 + 1] = uvs[index].y

    rl.UploadMesh(ptr_of(ref_of(out_mesh)), false)
    return out_mesh

def clip_segment(v0: rl.Vector3, v1: rl.Vector3, plane: rl.Vector3, distance: f32) -> rl.Vector3:
    let d0 = v0.dot(plane) - distance
    let d1 = v1.dot(plane) - distance
    let amount = d0 / (d0 - d1)
    return v0.lerp(v1, amount)

def minf(a: f32, b: f32) -> f32:
    if a < b:
        return a
    return b

def gen_mesh_decal(target: rl.Model, projection: rl.Matrix, decal_size: f32, decal_offset: f32) -> rl.Mesh:
    let inv_proj = projection.invert()
    var mesh_builders = zero[array[MeshBuilder, 2]]()
    defer:
        free_mesh_builder(ref_of(mesh_builders[0]))
        free_mesh_builder(ref_of(mesh_builders[1]))

    var mb_index = 0

    for mesh_index in range(0, target.meshCount):
        let mesh = model_mesh(target, mesh_index)
        for triangle_index in range(0, mesh.triangleCount):
            var vertices = mesh_triangle(mesh, triangle_index)
            var inside_count = 0

            for index in range(0, 3):
                let projected = vertices[index].transform(projection)
                if libm.fabsf(projected.x) < decal_size or libm.fabsf(projected.y) <= decal_size or libm.fabsf(projected.z) <= decal_size:
                    inside_count += 1
                vertices[index] = projected

            if inside_count > 0:
                add_triangle_to_mesh_builder(ref_of(mesh_builders[mb_index]), vertices)

    var planes = zero[array[rl.Vector3, 6]]()
    planes[0] = rl.Vector3(x = 1.0, y = 0.0, z = 0.0)
    planes[1] = rl.Vector3(x = -1.0, y = 0.0, z = 0.0)
    planes[2] = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    planes[3] = rl.Vector3(x = 0.0, y = -1.0, z = 0.0)
    planes[4] = rl.Vector3(x = 0.0, y = 0.0, z = 1.0)
    planes[5] = rl.Vector3(x = 0.0, y = 0.0, z = -1.0)

    for face in range(0, 6):
        mb_index = 1 - mb_index

        let in_index = 1 - mb_index
        let in_mesh = ref_of(mesh_builders[in_index])
        let out_mesh = ref_of(mesh_builders[mb_index])
        out_mesh.vertexCount = 0

        let clip_distance = 0.5 * decal_size
        let in_vertices = sp.from_ptr[rl.Vector3](in_mesh.vertices, usize<-in_mesh.vertexCount)

        var vertex_index = 0
        while vertex_index < in_mesh.vertexCount:
            var next_v1 = zero[rl.Vector3]()
            var next_v2 = zero[rl.Vector3]()
            var next_v3 = zero[rl.Vector3]()
            var next_v4 = zero[rl.Vector3]()

            let d1 = in_vertices[vertex_index].dot(planes[face]) - clip_distance
            let d2 = in_vertices[vertex_index + 1].dot(planes[face]) - clip_distance
            let d3 = in_vertices[vertex_index + 2].dot(planes[face]) - clip_distance

            let v1_out = if d1 > 0.0: 1 else: 0
            let v2_out = if d2 > 0.0: 1 else: 0
            let v3_out = if d3 > 0.0: 1 else: 0
            let total = v1_out + v2_out + v3_out

            if total == 0:
                add_triangle_to_mesh_builder(out_mesh, triangle_vertices(in_vertices[vertex_index], in_vertices[vertex_index + 1], in_vertices[vertex_index + 2]))
            elif total == 1:
                if v1_out == 1:
                    next_v1 = in_vertices[vertex_index + 1]
                    next_v2 = in_vertices[vertex_index + 2]
                    next_v3 = clip_segment(in_vertices[vertex_index], next_v1, planes[face], clip_distance)
                    next_v4 = clip_segment(in_vertices[vertex_index], next_v2, planes[face], clip_distance)

                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v1, next_v2, next_v3))
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v4, next_v3, next_v2))
                elif v2_out == 1:
                    next_v1 = in_vertices[vertex_index]
                    next_v2 = in_vertices[vertex_index + 2]
                    next_v3 = clip_segment(in_vertices[vertex_index + 1], next_v1, planes[face], clip_distance)
                    next_v4 = clip_segment(in_vertices[vertex_index + 1], next_v2, planes[face], clip_distance)

                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v3, next_v2, next_v1))
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v2, next_v3, next_v4))
                else:
                    next_v1 = in_vertices[vertex_index]
                    next_v2 = in_vertices[vertex_index + 1]
                    next_v3 = clip_segment(in_vertices[vertex_index + 2], next_v1, planes[face], clip_distance)
                    next_v4 = clip_segment(in_vertices[vertex_index + 2], next_v2, planes[face], clip_distance)

                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v1, next_v2, next_v3))
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v4, next_v3, next_v2))
            elif total == 2:
                if v1_out == 0:
                    next_v1 = in_vertices[vertex_index]
                    next_v2 = clip_segment(next_v1, in_vertices[vertex_index + 1], planes[face], clip_distance)
                    next_v3 = clip_segment(next_v1, in_vertices[vertex_index + 2], planes[face], clip_distance)
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v1, next_v2, next_v3))

                if v2_out == 0:
                    next_v1 = in_vertices[vertex_index + 1]
                    next_v2 = clip_segment(next_v1, in_vertices[vertex_index + 2], planes[face], clip_distance)
                    next_v3 = clip_segment(next_v1, in_vertices[vertex_index], planes[face], clip_distance)
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v1, next_v2, next_v3))

                if v3_out == 0:
                    next_v1 = in_vertices[vertex_index + 2]
                    next_v2 = clip_segment(next_v1, in_vertices[vertex_index], planes[face], clip_distance)
                    next_v3 = clip_segment(next_v1, in_vertices[vertex_index + 1], planes[face], clip_distance)
                    add_triangle_to_mesh_builder(out_mesh, triangle_vertices(next_v1, next_v2, next_v3))

            vertex_index += 3

    let final_mesh = ref_of(mesh_builders[mb_index])
    if final_mesh.vertexCount > 0:
        final_mesh.uvs = alloc_vector2(final_mesh.vertexCount)
        final_mesh.hasUvs = true

        var vertices = sp.from_ptr[rl.Vector3](final_mesh.vertices, usize<-final_mesh.vertexCount)
        var uvs = sp.from_ptr[rl.Vector2](final_mesh.uvs, usize<-final_mesh.vertexCount)

        for index in range(0, final_mesh.vertexCount):
            uvs[index].x = vertices[index].x / decal_size + 0.5
            uvs[index].y = vertices[index].y / decal_size + 0.5
            vertices[index].z -= decal_offset
            vertices[index] = vertices[index].transform(inv_proj)

        return build_mesh(final_mesh)

    return zero[rl.Mesh]()

def gui_button(rec: rl.Rectangle, label: cstr) -> bool:
    var background_color = rl.GRAY
    var pressed = false

    if rl.CheckCollisionPointRec(rl.GetMousePosition(), rec):
        background_color = rl.LIGHTGRAY
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            pressed = true

    rl.DrawRectangleRec(rec, background_color)
    rl.DrawRectangleLinesEx(rec, 2.0, rl.DARKGRAY)

    let font_size = 10
    let text_width = rl.MeasureText(label, font_size)
    rl.DrawText(label, i32<-(rec.x + rec.width * 0.5 - f32<-text_width * 0.5), i32<-(rec.y + rec.height * 0.5 - f32<-font_size * 0.5), font_size, rl.DARKGRAY)

    return pressed

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.6, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(character_model_path)
    defer rl.UnloadModel(model)

    let model_texture = rl.LoadTexture(character_texture_path)
    defer rl.UnloadTexture(model_texture)
    rl.SetTextureFilter(model_texture, i32<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, model_texture)

    let model_bbox = rl.GetMeshBoundingBox(model_mesh(model, 0))
    camera.target = model_bbox.min.lerp(model_bbox.max, 0.5)
    camera.position = model_bbox.max.scale(1.0)
    camera.position.x *= 0.1

    let model_size = minf(
        minf(libm.fabsf(model_bbox.max.x - model_bbox.min.x), libm.fabsf(model_bbox.max.y - model_bbox.min.y)),
        libm.fabsf(model_bbox.max.z - model_bbox.min.z),
    )

    camera.position = rl.Vector3(x = 0.0, y = model_bbox.max.y * 1.2, z = model_size * 3.0)

    let decal_size = model_size * 0.25
    let decal_offset: f32 = 0.01

    var placement_cube = rl.LoadModelFromMesh(rl.GenMeshCube(decal_size, decal_size, decal_size))
    defer rl.UnloadModel(placement_cube)
    unsafe:
        placement_cube.materials[0].maps[0].color = rl.LIME

    var decal_material = rl.LoadMaterialDefault()
    unsafe:
        decal_material.maps[0].color = rl.YELLOW

    var decal_image = rl.LoadImage(decal_texture_path)
    rl.ImageResizeNN(ptr_of(ref_of(decal_image)), decal_image.width / 4, decal_image.height / 4)
    let decal_texture = rl.LoadTextureFromImage(decal_image)
    defer rl.UnloadTexture(decal_texture)
    rl.UnloadImage(decal_image)

    rl.SetTextureFilter(decal_texture, i32<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    unsafe:
        decal_material.maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].texture = decal_texture
        decal_material.maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.RAYWHITE

    var show_model = true
    var decal_models = zero[array[rl.Model, 256]]()
    var decal_count = 0
    defer:
        for index in range(0, decal_count):
            rl.UnloadModel(decal_models[index])

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_THIRD_PERSON)

        var collision = zero[rl.RayCollision]()
        collision.distance = float_max
        collision.hit = false

        let ray = rl.GetScreenToWorldRay(rl.GetMousePosition(), camera)
        let box_hit_info = rl.GetRayCollisionBox(ray, model_bbox)

        if box_hit_info.hit and decal_count < max_decals:
            var mesh_hit_info = zero[rl.RayCollision]()
            for mesh_index in range(0, model.meshCount):
                mesh_hit_info = rl.GetRayCollisionMesh(ray, model_mesh(model, mesh_index), model.transform)
                if mesh_hit_info.hit:
                    if not collision.hit or collision.distance > mesh_hit_info.distance:
                        collision = mesh_hit_info

            if mesh_hit_info.hit:
                collision = mesh_hit_info

        if collision.hit and rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and decal_count < max_decals:
            let origin = collision.point.add(collision.normal.scale(1.0))
            var splat = rm.Matrix.look_at(collision.point, origin, rl.Vector3(x = 0.0, y = 1.0, z = 0.0))
            splat = splat.multiply(rm.Matrix.rotate_z(rm.deg2rad * f32<-rl.GetRandomValue(-180, 180)))

            let decal_mesh = gen_mesh_decal(model, splat, decal_size, decal_offset)
            if decal_mesh.vertexCount > 0:
                let decal_index = decal_count
                decal_count += 1
                decal_models[decal_index] = rl.LoadModelFromMesh(decal_mesh)
                unsafe:
                    decal_models[decal_index].materials[0].maps[0] = material_map(decal_material, 0)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        if show_model:
            rl.DrawModel(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)

        for index in range(0, decal_count):
            rl.DrawModel(decal_models[index], rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)

        if collision.hit:
            let origin = collision.point.add(collision.normal.scale(1.0))
            let splat = rm.Matrix.look_at(collision.point, origin, rl.Vector3(x = 0.0, y = 1.0, z = 0.0))
            placement_cube.transform = splat.invert()
            rl.DrawModel(placement_cube, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.Fade(rl.WHITE, 0.5))

        rl.DrawGrid(10, 10.0)
        rl.EndMode3D()

        var y_pos = 10.0
        let x0 = rl.GetScreenWidth() - 300.0
        let x1 = x0 + 100.0
        let x2 = x1 + 100.0

        rl.DrawText(vertices_text, i32<-x1, i32<-y_pos, 10, rl.LIME)
        rl.DrawText(triangles_text, i32<-x2, i32<-y_pos, 10, rl.LIME)
        y_pos += 15.0

        var vertex_count = 0
        var triangle_count = 0
        for mesh_index in range(0, model.meshCount):
            let mesh = model_mesh(model, mesh_index)
            vertex_count += mesh.vertexCount
            triangle_count += mesh.triangleCount

        rl.DrawText(main_model_text, i32<-x0, i32<-y_pos, 10, rl.LIME)
        rl.DrawText(rl.TextFormat(count_format, vertex_count), i32<-x1, i32<-y_pos, 10, rl.LIME)
        rl.DrawText(rl.TextFormat(count_format, triangle_count), i32<-x2, i32<-y_pos, 10, rl.LIME)
        y_pos += 15.0

        for index in range(0, decal_count):
            if index == 20:
                rl.DrawText(ellipsis_text, i32<-x0, i32<-y_pos, 10, rl.LIME)
                y_pos += 15.0

            if index < 20:
                let mesh = model_mesh(decal_models[index], 0)
                rl.DrawText(rl.TextFormat(decal_label_format, index + 1), i32<-x0, i32<-y_pos, 10, rl.LIME)
                rl.DrawText(rl.TextFormat(count_format, mesh.vertexCount), i32<-x1, i32<-y_pos, 10, rl.LIME)
                rl.DrawText(rl.TextFormat(count_format, mesh.triangleCount), i32<-x2, i32<-y_pos, 10, rl.LIME)
                y_pos += 15.0

            vertex_count += model_mesh(decal_models[index], 0).vertexCount
            triangle_count += model_mesh(decal_models[index], 0).triangleCount

        rl.DrawText(total_text, i32<-x0, i32<-y_pos, 10, rl.LIME)
        rl.DrawText(rl.TextFormat(count_format, vertex_count), i32<-x1, i32<-y_pos, 10, rl.LIME)
        rl.DrawText(rl.TextFormat(count_format, triangle_count), i32<-x2, i32<-y_pos, 10, rl.LIME)

        rl.DrawText(hold_camera_text, 10, 430, 10, rl.GRAY)
        rl.DrawText(credit_text, screen_width - 260, screen_height - 20, 10, rl.GRAY)

        if gui_button(rl.Rectangle(x = 10.0, y = screen_height - 100.0, width = 100.0, height = 60.0), if show_model: hide_model_text else: show_model_text):
            show_model = not show_model

        if gui_button(rl.Rectangle(x = 120.0, y = screen_height - 100.0, width = 100.0, height = 60.0), clear_decals_text):
            for index in range(0, decal_count):
                rl.UnloadModel(decal_models[index])
            decal_count = 0

        rl.DrawFPS(10, 10)

    return 0