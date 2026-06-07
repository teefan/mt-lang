import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - first person maze")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.2, y = 0.4, z = 0.2),
        target = rl.Vector3(x = 0.185, y = 0.4, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let map_image = rl.load_image("cubicmap.png")
    defer rl.unload_image(map_image)
    let cubicmap = rl.load_texture_from_image(map_image)
    defer rl.unload_texture(cubicmap)

    let model = rl.load_model_from_mesh(rl.gen_mesh_cubicmap(map_image, rl.Vector3(x = 1.0, y = 1.0, z = 1.0)))
    defer rl.unload_model(model)
    let texture = rl.load_texture("cubicmap_atlas.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let map_pixels = rl.load_image_colors(map_image) else:
        fatal("could not load image colors")
    defer rl.unload_image_colors(map_pixels)

    let map_position = rl.Vector3(x = -16.0, y = 0.0, z = -8.0)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        let old_camera_position = camera.position

        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        let player_position = rl.Vector2(x = camera.position.x, y = camera.position.z)
        let player_radius = float<-0.1

        var player_cell_x = int<-(player_position.x - map_position.x + 0.5)
        var player_cell_y = int<-(player_position.y - map_position.z + 0.5)

        if player_cell_x < 0:
            player_cell_x = 0
        else if player_cell_x >= cubicmap.width:
            player_cell_x = cubicmap.width - 1

        if player_cell_y < 0:
            player_cell_y = 0
        else if player_cell_y >= cubicmap.height:
            player_cell_y = cubicmap.height - 1

        var y = player_cell_y - 1
        while y <= player_cell_y + 1:
            if y >= 0 and y < cubicmap.height:
                var x = player_cell_x - 1
                while x <= player_cell_x + 1:
                    if x >= 0 and x < cubicmap.width:
                        let pixel = unsafe: map_pixels[y * cubicmap.width + x]
                        let hit_wall = pixel.r == 255
                        let wall_rect = rl.Rectangle(
                            x = map_position.x - 0.5 + float<-x,
                            y = map_position.z - 0.5 + float<-y,
                            width = 1.0,
                            height = 1.0
                        )
                        if hit_wall and rl.check_collision_circle_rec(player_position, player_radius, wall_rect):
                            camera.position = old_camera_position
                    x += 1
            y += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, map_position, 1.0, rl.WHITE)
        rl.end_mode_3d()

        rl.draw_texture_ex(
            cubicmap,
            rl.Vector2(x = float<-(rl.get_screen_width() - cubicmap.width * 4 - 20), y = 20.0),
            0.0,
            4.0,
            rl.WHITE
        )
        rl.draw_rectangle_lines(
            rl.get_screen_width() - cubicmap.width * 4 - 20,
            20,
            cubicmap.width * 4,
            cubicmap.height * 4,
            rl.GREEN
        )
        rl.draw_rectangle(
            rl.get_screen_width() - cubicmap.width * 4 - 20 + player_cell_x * 4,
            20 + player_cell_y * 4,
            4,
            4,
            rl.RED
        )
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
