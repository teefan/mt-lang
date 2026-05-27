import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FLOAT_MAX: float = 340282346638528859811704183484516925440.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - mesh picking")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 20.0, y = 20.0, z = 20.0),
        target = rl.Vector3(x = 0.0, y = 8.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.6, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var ray = zero[rl.Ray]

    let tower = rl.load_model("models/obj/turret.obj")
    defer rl.unload_model(tower)
    let texture = rl.load_texture("models/obj/turret_diffuse.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(tower.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let tower_pos = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    let tower_bbox = rl.get_mesh_bounding_box(unsafe: tower.meshes[0])

    let g0 = rl.Vector3(x = -50.0, y = 0.0, z = -50.0)
    let g1 = rl.Vector3(x = -50.0, y = 0.0, z = 50.0)
    let g2 = rl.Vector3(x = 50.0, y = 0.0, z = 50.0)
    let g3 = rl.Vector3(x = 50.0, y = 0.0, z = -50.0)

    let ta = rl.Vector3(x = -25.0, y = 0.5, z = 0.0)
    let tb = rl.Vector3(x = -4.0, y = 2.5, z = 1.0)
    let tc = rl.Vector3(x = -8.0, y = 6.5, z = 0.0)

    var bary = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let sphere_position = rl.Vector3(x = -30.0, y = 5.0, z = 5.0)
    let sphere_radius = float<-4.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_cursor_hidden():
            rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.is_cursor_hidden():
                rl.enable_cursor()
            else:
                rl.disable_cursor()

        var collision = zero[rl.RayCollision]
        var hit_object_name = "None"
        collision.distance = FLOAT_MAX
        collision.hit = false
        var cursor_color = rl.WHITE

        ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)

        let ground_hit_info = rl.get_ray_collision_quad(ray, g0, g1, g2, g3)
        if ground_hit_info.hit and ground_hit_info.distance < collision.distance:
            collision = ground_hit_info
            cursor_color = rl.GREEN
            hit_object_name = "Ground"

        let tri_hit_info = rl.get_ray_collision_triangle(ray, ta, tb, tc)
        if tri_hit_info.hit and tri_hit_info.distance < collision.distance:
            collision = tri_hit_info
            cursor_color = rl.PURPLE
            hit_object_name = "Triangle"
            bary = rm.vector3_barycenter(collision.point, ta, tb, tc)

        let sphere_hit_info = rl.get_ray_collision_sphere(ray, sphere_position, sphere_radius)
        if sphere_hit_info.hit and sphere_hit_info.distance < collision.distance:
            collision = sphere_hit_info
            cursor_color = rl.ORANGE
            hit_object_name = "Sphere"

        let box_hit_info = rl.get_ray_collision_box(ray, tower_bbox)
        if box_hit_info.hit and box_hit_info.distance < collision.distance:
            collision = box_hit_info
            cursor_color = rl.ORANGE
            hit_object_name = "Box"

            var mesh_hit_info = zero[rl.RayCollision]
            var mesh_index = 0
            while mesh_index < tower.meshCount:
                mesh_hit_info = rl.get_ray_collision_mesh(ray, unsafe: tower.meshes[mesh_index], tower.transform)
                if mesh_hit_info.hit:
                    if not collision.hit or collision.distance > mesh_hit_info.distance:
                        collision = mesh_hit_info
                    break
                mesh_index += 1

            if mesh_hit_info.hit:
                collision = mesh_hit_info
                cursor_color = rl.ORANGE
                hit_object_name = "Mesh"

        let hit_object_text = rl.text_format("Hit Object: %s", hit_object_name)
        let distance_text = rl.text_format("Distance: %3.2f", collision.distance)
        let hit_pos_text = rl.text_format("Hit Pos: %3.2f %3.2f %3.2f", collision.point.x, collision.point.y, collision.point.z)
        let hit_norm_text = rl.text_format("Hit Norm: %3.2f %3.2f %3.2f", collision.normal.x, collision.normal.y, collision.normal.z)
        let barycenter_text = rl.text_format("Barycenter: %3.2f %3.2f %3.2f", bary.x, bary.y, bary.z)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(tower, tower_pos, 1.0, rl.WHITE)
        rl.draw_line_3d(ta, tb, rl.PURPLE)
        rl.draw_line_3d(tb, tc, rl.PURPLE)
        rl.draw_line_3d(tc, ta, rl.PURPLE)
        rl.draw_sphere_wires(sphere_position, sphere_radius, 8, 8, rl.PURPLE)

        if box_hit_info.hit:
            rl.draw_bounding_box(tower_bbox, rl.LIME)

        if collision.hit:
            rl.draw_cube(collision.point, 0.3, 0.3, 0.3, cursor_color)
            rl.draw_cube_wires(collision.point, 0.3, 0.3, 0.3, rl.RED)
            let normal_end = rl.Vector3(
                x = collision.point.x + collision.normal.x,
                y = collision.point.y + collision.normal.y,
                z = collision.point.z + collision.normal.z,
            )
            rl.draw_line_3d(collision.point, normal_end, rl.RED)

        rl.draw_ray(ray, rl.MAROON)
        rl.draw_grid(10, 10.0)
        rl.end_mode_3d()

        rl.draw_text(hit_object_text, 10, 50, 10, rl.BLACK)
        if collision.hit:
            let y = 70
            rl.draw_text(distance_text, 10, y, 10, rl.BLACK)
            rl.draw_text(hit_pos_text, 10, y + 15, 10, rl.BLACK)
            rl.draw_text(hit_norm_text, 10, y + 30, 10, rl.BLACK)
            if tri_hit_info.hit and hit_object_name == "Triangle":
                rl.draw_text(barycenter_text, 10, y + 45, 10, rl.BLACK)

        rl.draw_text("Right click mouse to toggle camera controls", 10, 430, 10, rl.GRAY)
        rl.draw_text("(c) Turret 3D model by Alberto Cano", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
