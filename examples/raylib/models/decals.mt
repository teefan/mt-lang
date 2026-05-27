import std.c.raylib as c
import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.vec as vec


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_DECALS: int = 256
const FLOAT_MAX: float = 340282346638528859811704183484516925440.0
const DEG_TO_RAD: float = rl.PI / 180.0


struct MeshBuilder:
    vertices: vec.Vec[rl.Vector3]
    uvs: vec.Vec[rl.Vector2]


function create_mesh_builder() -> MeshBuilder:
    return MeshBuilder(
        vertices = vec.Vec[rl.Vector3].create(),
        uvs = vec.Vec[rl.Vector2].create(),
    )


function release_mesh_builder(builder: ref[MeshBuilder]) -> void:
    builder.vertices.release()
    builder.uvs.release()


function add_triangle_to_mesh_builder(builder: ref[MeshBuilder], a: rl.Vector3, b: rl.Vector3, c: rl.Vector3) -> void:
    builder.vertices.push(a)
    builder.vertices.push(b)
    builder.vertices.push(c)


function build_mesh(builder: MeshBuilder) -> rl.Mesh:
    let vertex_count = int<-builder.vertices.len()
    if vertex_count == 0:
        return zero[rl.Mesh]

    let raw_vertices = c.MemAlloc(uint<-(vertex_count * 3 * int<-size_of(float))) else:
        fatal("failed to allocate decal mesh vertices")
    let vertices = unsafe: ptr[float]<-raw_vertices

    let raw_texcoords = c.MemAlloc(uint<-(vertex_count * 2 * int<-size_of(float))) else:
        fatal("failed to allocate decal mesh UVs")
    let texcoords = unsafe: ptr[float]<-raw_texcoords

    var index = 0
    while index < vertex_count:
        let vertex_ptr = builder.vertices.get(ptr_uint<-index) else:
            fatal("missing decal mesh vertex")
        let uv_ptr = builder.uvs.get(ptr_uint<-index) else:
            fatal("missing decal mesh UV")
        let vertex = unsafe: read(vertex_ptr)
        let uv = unsafe: read(uv_ptr)

        unsafe: read(vertices + ptr_uint<-(index * 3 + 0)) = vertex.x
        unsafe: read(vertices + ptr_uint<-(index * 3 + 1)) = vertex.y
        unsafe: read(vertices + ptr_uint<-(index * 3 + 2)) = vertex.z

        unsafe: read(texcoords + ptr_uint<-(index * 2 + 0)) = uv.x
        unsafe: read(texcoords + ptr_uint<-(index * 2 + 1)) = uv.y

        index += 1

    var mesh = rl.Mesh(
        vertexCount = vertex_count,
        triangleCount = vertex_count / 3,
        vertices = vertices,
        texcoords = texcoords,
    )
    rl.upload_mesh(ptr_of(mesh), false)
    return mesh


function clip_segment(v0: rl.Vector3, v1: rl.Vector3, plane: rl.Vector3, distance: float) -> rl.Vector3:
    let d0 = rm.vector3_dot_product(v0, plane) - distance
    let d1 = rm.vector3_dot_product(v1, plane) - distance
    let factor = d0 / (d0 - d1)
    return rm.vector3_lerp(v0, v1, factor)


function triangle_vertex(mesh: rl.Mesh, triangle_index: int, corner_index: int) -> rl.Vector3:
    if mesh.indices == null:
        let base = triangle_index * 9 + corner_index * 3
        return rl.Vector3(
            x = unsafe: read(mesh.vertices + ptr_uint<-(base + 0)),
            y = unsafe: read(mesh.vertices + ptr_uint<-(base + 1)),
            z = unsafe: read(mesh.vertices + ptr_uint<-(base + 2)),
        )

    let indices = mesh.indices else:
        fatal("indexed mesh is missing indices")
    let vertex_index = int<-(unsafe: read(indices + ptr_uint<-(triangle_index * 3 + corner_index)))
    let base = vertex_index * 3
    return rl.Vector3(
        x = unsafe: read(mesh.vertices + ptr_uint<-(base + 0)),
        y = unsafe: read(mesh.vertices + ptr_uint<-(base + 1)),
        z = unsafe: read(mesh.vertices + ptr_uint<-(base + 2)),
    )


function gen_mesh_decal(target: rl.Model, projection: rl.Matrix, decal_size: float, decal_offset: float) -> rl.Mesh:
    let planes = array[rl.Vector3, 6](
        rl.Vector3(x = 1.0, y = 0.0, z = 0.0),
        rl.Vector3(x = -1.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        rl.Vector3(x = 0.0, y = -1.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 1.0),
        rl.Vector3(x = 0.0, y = 0.0, z = -1.0),
    )

    let inverse_projection = rm.matrix_invert(projection)
    let clip_distance = decal_size * 0.5

    var read_builder = create_mesh_builder()
    defer release_mesh_builder(ref_of(read_builder))
    var write_builder = create_mesh_builder()
    defer release_mesh_builder(ref_of(write_builder))

    var mesh_index = 0
    while mesh_index < target.meshCount:
        let mesh = unsafe: target.meshes[mesh_index]

        var triangle_index = 0
        while triangle_index < mesh.triangleCount:
            let a = rm.vector3_transform(triangle_vertex(mesh, triangle_index, 0), projection)
            let b = rm.vector3_transform(triangle_vertex(mesh, triangle_index, 1), projection)
            let c = rm.vector3_transform(triangle_vertex(mesh, triangle_index, 2), projection)
            add_triangle_to_mesh_builder(ref_of(read_builder), a, b, c)
            triangle_index += 1

        mesh_index += 1

    var plane_index = 0
    while plane_index < 6:
        write_builder.vertices.clear()
        write_builder.uvs.clear()

        let input_vertices = read_builder.vertices.as_span()
        let input_count = int<-input_vertices.len
        let plane = planes[plane_index]

        var index = 0
        while index < input_count:
            let v0 = unsafe: read(input_vertices.data + ptr_uint<-(index + 0))
            let v1 = unsafe: read(input_vertices.data + ptr_uint<-(index + 1))
            let v2 = unsafe: read(input_vertices.data + ptr_uint<-(index + 2))

            let d0 = rm.vector3_dot_product(v0, plane) - clip_distance
            let d1 = rm.vector3_dot_product(v1, plane) - clip_distance
            let d2 = rm.vector3_dot_product(v2, plane) - clip_distance

            let v0_outside = d0 > 0.0
            let v1_outside = d1 > 0.0
            let v2_outside = d2 > 0.0

            var outside_count = 0
            if v0_outside:
                outside_count += 1
            if v1_outside:
                outside_count += 1
            if v2_outside:
                outside_count += 1

            if outside_count == 0:
                add_triangle_to_mesh_builder(ref_of(write_builder), v0, v1, v2)
            else if outside_count == 1:
                if v0_outside:
                    let nv0 = clip_segment(v0, v1, plane, clip_distance)
                    let nv1 = clip_segment(v0, v2, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, v1, v2)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, v2, nv1)
                else if v1_outside:
                    let nv0 = clip_segment(v1, v0, plane, clip_distance)
                    let nv1 = clip_segment(v1, v2, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), v0, nv0, v2)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, nv1, v2)
                else:
                    let nv0 = clip_segment(v2, v0, plane, clip_distance)
                    let nv1 = clip_segment(v2, v1, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), v0, v1, nv0)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, v1, nv1)
            else if outside_count == 2:
                if not v0_outside:
                    let nv0 = clip_segment(v0, v1, plane, clip_distance)
                    let nv1 = clip_segment(v0, v2, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), v0, nv0, nv1)
                else if not v1_outside:
                    let nv0 = clip_segment(v1, v0, plane, clip_distance)
                    let nv1 = clip_segment(v1, v2, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, v1, nv1)
                else:
                    let nv0 = clip_segment(v2, v0, plane, clip_distance)
                    let nv1 = clip_segment(v2, v1, plane, clip_distance)
                    add_triangle_to_mesh_builder(ref_of(write_builder), nv0, nv1, v2)

            index += 3

        let next_builder = read_builder
        read_builder = write_builder
        write_builder = next_builder
        plane_index += 1

    let projected_vertices = read_builder.vertices.as_span()
    let projected_count = int<-projected_vertices.len
    var index = 0
    while index < projected_count:
        let vertex_ptr = read_builder.vertices.get(ptr_uint<-index) else:
            fatal("missing projected decal vertex")
        let projected = unsafe: read(vertex_ptr)

        read_builder.uvs.push(
            rl.Vector2(
                x = 0.5 + projected.x / decal_size,
                y = 0.5 + projected.y / decal_size,
            )
        )

        var adjusted = projected
        adjusted.z -= decal_offset
        unsafe: read(vertex_ptr) = rm.vector3_transform(adjusted, inverse_projection)
        index += 1

    return build_mesh(read_builder)


function draw_button(bounds: rl.Rectangle, label: str) -> bool:
    var background = rl.GRAY
    if rl.check_collision_point_rec(rl.get_mouse_position(), bounds):
        background = rl.LIGHTGRAY
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            background = rl.DARKGRAY
            rl.draw_rectangle_rec(bounds, background)
            rl.draw_rectangle_lines_ex(bounds, 2.0, rl.DARKGRAY)
            let text_width = rl.measure_text(label, 10)
            rl.draw_text(label, int<-(bounds.x + bounds.width * 0.5 - float<-text_width * 0.5), int<-(bounds.y + bounds.height * 0.5 - 5.0), 10, rl.RAYWHITE)
            return true

    rl.draw_rectangle_rec(bounds, background)
    rl.draw_rectangle_lines_ex(bounds, 2.0, rl.DARKGRAY)
    let text_width = rl.measure_text(label, 10)
    rl.draw_text(label, int<-(bounds.x + bounds.width * 0.5 - float<-text_width * 0.5), int<-(bounds.y + bounds.height * 0.5 - 5.0), 10, rl.DARKGRAY)
    return false


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - decals")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.6, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/obj/character.obj")
    defer rl.unload_model(model)

    let model_texture = rl.load_texture("models/obj/character_diffuse.png")
    defer rl.unload_texture(model_texture)
    rl.set_texture_filter(model_texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, model_texture)

    let model_bbox = rl.get_model_bounding_box(model)
    camera.target = rm.vector3_lerp(model_bbox.min, model_bbox.max, 0.5)
    camera.position = model_bbox.max
    camera.position.x *= 0.1

    let size_x = float<-math.abs(double<-(model_bbox.max.x - model_bbox.min.x))
    let size_y = float<-math.abs(double<-(model_bbox.max.y - model_bbox.min.y))
    let size_z = float<-math.abs(double<-(model_bbox.max.z - model_bbox.min.z))
    var model_size = size_x
    if size_y < model_size:
        model_size = size_y
    if size_z < model_size:
        model_size = size_z

    camera.position = rl.Vector3(x = 0.0, y = model_bbox.max.y * 1.2, z = model_size * 3.0)

    let decal_size = model_size * 0.25
    let decal_offset: float = 0.01

    var placement_cube = rl.load_model_from_mesh(rl.gen_mesh_cube(decal_size, decal_size, decal_size))
    defer rl.unload_model(placement_cube)
    unsafe: placement_cube.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.LIME

    var decal_material = rl.load_material_default()
    unsafe: decal_material.maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.YELLOW

    var decal_image = rl.load_image("raylib_logo.png")
    rl.image_resize_nn(decal_image, decal_image.width / 4, decal_image.height / 4)
    let decal_texture = rl.load_texture_from_image(decal_image)
    defer rl.unload_texture(decal_texture)
    rl.unload_image(decal_image)

    rl.set_texture_filter(decal_texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    let albedo_index = int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO
    unsafe: decal_material.maps[albedo_index].texture = decal_texture
    unsafe: decal_material.maps[albedo_index].color = rl.RAYWHITE
    let decal_map = unsafe: decal_material.maps[albedo_index]

    var show_model = true
    var decal_models = zero[array[rl.Model, MAX_DECALS]]
    var decal_count = 0
    defer:
        var index = 0
        while index < decal_count:
            rl.unload_model(decal_models[index])
            index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            rl.update_camera(camera, rl.CameraMode.CAMERA_THIRD_PERSON)

        var collision = rl.RayCollision(distance = FLOAT_MAX)
        let ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
        let box_hit_info = rl.get_ray_collision_box(ray, model_bbox)

        if box_hit_info.hit and decal_count < MAX_DECALS:
            var mesh_index = 0
            while mesh_index < model.meshCount:
                let mesh_hit_info = rl.get_ray_collision_mesh(ray, unsafe: model.meshes[mesh_index], model.transform)
                if mesh_hit_info.hit and (not collision.hit or mesh_hit_info.distance < collision.distance):
                    collision = mesh_hit_info
                mesh_index += 1

        if collision.hit and rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and decal_count < MAX_DECALS:
            let origin = rm.vector3_add(collision.point, rm.vector3_scale(collision.normal, 1.0))
            var splat = rm.matrix_look_at(collision.point, origin, rl.Vector3(x = 0.0, y = 1.0, z = 0.0))
            let angle = DEG_TO_RAD * float<-rl.get_random_value(-180, 180)
            splat = rm.matrix_multiply(splat, rm.matrix_rotate_z(angle))

            let decal_mesh = gen_mesh_decal(model, splat, decal_size, decal_offset)
            if decal_mesh.vertexCount > 0:
                let decal_index = decal_count
                decal_count += 1
                decal_models[decal_index] = rl.load_model_from_mesh(decal_mesh)
                unsafe: decal_models[decal_index].materials[0].maps[albedo_index] = decal_map

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        if show_model:
            rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)

        var decal_index = 0
        while decal_index < decal_count:
            rl.draw_model(decal_models[decal_index], rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
            decal_index += 1

        if collision.hit:
            let origin = rm.vector3_add(collision.point, rm.vector3_scale(collision.normal, 1.0))
            let splat = rm.matrix_look_at(collision.point, origin, rl.Vector3(x = 0.0, y = 1.0, z = 0.0))
            placement_cube.transform = rm.matrix_invert(splat)
            rl.draw_model(placement_cube, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.fade(rl.WHITE, 0.5))

        rl.draw_grid(10, 10.0)
        rl.end_mode_3d()

        var y_position = 10.0
        let x0 = float<-rl.get_screen_width() - 300.0
        let x1 = x0 + 100.0
        let x2 = x1 + 100.0

        rl.draw_text("Vertices", int<-x1, int<-y_position, 10, rl.LIME)
        rl.draw_text("Triangles", int<-x2, int<-y_position, 10, rl.LIME)
        y_position += 15.0

        var model_vertex_count = 0
        var model_triangle_count = 0
        var mesh_index = 0
        while mesh_index < model.meshCount:
            model_vertex_count += unsafe: model.meshes[mesh_index].vertexCount
            model_triangle_count += unsafe: model.meshes[mesh_index].triangleCount
            mesh_index += 1

        rl.draw_text("Main model", int<-x0, int<-y_position, 10, rl.LIME)
        let main_vertices_text = rl.text_format("%d", model_vertex_count)
        let main_triangles_text = rl.text_format("%d", model_triangle_count)
        rl.draw_text(main_vertices_text, int<-x1, int<-y_position, 10, rl.LIME)
        rl.draw_text(main_triangles_text, int<-x2, int<-y_position, 10, rl.LIME)
        y_position += 15.0

        var decal_vertex_count = 0
        var decal_triangle_count = 0
        decal_index = 0
        while decal_index < decal_count:
            if decal_index == 20:
                rl.draw_text("...", int<-x0, int<-y_position, 10, rl.LIME)
                y_position += 15.0

            let decal_model = decal_models[decal_index]
            let vertex_count = unsafe: decal_model.meshes[0].vertexCount
            let triangle_count = unsafe: decal_model.meshes[0].triangleCount

            if decal_index < 20:
                let label = rl.text_format("Decal #%d", decal_index + 1)
                let vertices_text = rl.text_format("%d", vertex_count)
                let triangles_text = rl.text_format("%d", triangle_count)
                rl.draw_text(label, int<-x0, int<-y_position, 10, rl.LIME)
                rl.draw_text(vertices_text, int<-x1, int<-y_position, 10, rl.LIME)
                rl.draw_text(triangles_text, int<-x2, int<-y_position, 10, rl.LIME)
                y_position += 15.0

            decal_vertex_count += vertex_count
            decal_triangle_count += triangle_count
            decal_index += 1

        rl.draw_text("TOTAL", int<-x0, int<-y_position, 10, rl.LIME)
        let total_vertices_text = rl.text_format("%d", decal_vertex_count)
        let total_triangles_text = rl.text_format("%d", decal_triangle_count)
        rl.draw_text(total_vertices_text, int<-x1, int<-y_position, 10, rl.LIME)
        rl.draw_text(total_triangles_text, int<-x2, int<-y_position, 10, rl.LIME)

        rl.draw_text("Hold RMB to move camera", 10, 430, 10, rl.GRAY)
        rl.draw_text("(c) Character model and texture from kenney.nl", SCREEN_WIDTH - 260, SCREEN_HEIGHT - 20, 10, rl.GRAY)

        let show_model_label = if show_model: "Hide Model" else: "Show Model"
        if draw_button(
            rl.Rectangle(x = 10.0, y = float<-SCREEN_HEIGHT - 100.0, width = 100.0, height = 60.0),
            show_model_label,
        ):
            show_model = not show_model

        if draw_button(
            rl.Rectangle(x = 120.0, y = float<-SCREEN_HEIGHT - 100.0, width = 100.0, height = 60.0),
            "Clear Decals",
        ):
            var index = 0
            while index < decal_count:
                rl.unload_model(decal_models[index])
                index += 1
            decal_count = 0

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
