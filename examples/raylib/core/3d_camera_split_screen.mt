import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const HALF_SCREEN_WIDTH: int = SCREEN_WIDTH / 2
const GRID_COUNT: int = 5
const GRID_SPACING: float = 4.0
const PLAYER_MOVE_SPEED: float = 10.0
const TREE_CANOPY_Y: float = 1.5
const TREE_TRUNK_Y: float = 0.5
const TRUNK_WIDTH: float = 0.25


function draw_world(camera_player1: rl.Camera3D, camera_player2: rl.Camera3D) -> void:
    rl.draw_plane(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector2(x = 50.0, y = 50.0), rl.BEIGE)

    var x_index = -GRID_COUNT
    while x_index <= GRID_COUNT:
        let x = float<-x_index * GRID_SPACING
        var z_index = -GRID_COUNT
        while z_index <= GRID_COUNT:
            let z = float<-z_index * GRID_SPACING
            rl.draw_cube(rl.Vector3(x = x, y = TREE_CANOPY_Y, z = z), 1.0, 1.0, 1.0, rl.LIME)
            rl.draw_cube(rl.Vector3(x = x, y = TREE_TRUNK_Y, z = z), TRUNK_WIDTH, 1.0, TRUNK_WIDTH, rl.BROWN)
            z_index += 1
        x_index += 1

    rl.draw_cube(camera_player1.position, 1.0, 1.0, 1.0, rl.RED)
    rl.draw_cube(camera_player2.position, 1.0, 1.0, 1.0, rl.BLUE)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 3d camera split screen")

    var camera_player1 = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 1.0, z = -3.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )
    let screen_player1 = rl.load_render_texture(HALF_SCREEN_WIDTH, SCREEN_HEIGHT)

    var camera_player2 = rl.Camera3D(
        position = rl.Vector3(x = -3.0, y = 3.0, z = 0.0),
        target = rl.Vector3(x = 0.0, y = 3.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )
    let screen_player2 = rl.load_render_texture(HALF_SCREEN_WIDTH, SCREEN_HEIGHT)
    let split_screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-screen_player1.texture.width,
        height = -float<-screen_player1.texture.height
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let offset_this_frame = PLAYER_MOVE_SPEED * rl.get_frame_time()

        if rl.is_key_down(rl.KeyboardKey.KEY_W):
            camera_player1.position.z += offset_this_frame
            camera_player1.target.z += offset_this_frame
        else if rl.is_key_down(rl.KeyboardKey.KEY_S):
            camera_player1.position.z -= offset_this_frame
            camera_player1.target.z -= offset_this_frame

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            camera_player2.position.x += offset_this_frame
            camera_player2.target.x += offset_this_frame
        else if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            camera_player2.position.x -= offset_this_frame
            camera_player2.target.x -= offset_this_frame

        rl.begin_texture_mode(screen_player1)
        rl.clear_background(rl.SKYBLUE)
        rl.begin_mode_3d(camera_player1)
        draw_world(camera_player1, camera_player2)
        rl.end_mode_3d()
        rl.draw_rectangle(0, 0, HALF_SCREEN_WIDTH, 40, rl.fade(rl.RAYWHITE, 0.8))
        rl.draw_text("PLAYER1: W/S to move", 10, 10, 20, rl.MAROON)
        rl.end_texture_mode()

        rl.begin_texture_mode(screen_player2)
        rl.clear_background(rl.SKYBLUE)
        rl.begin_mode_3d(camera_player2)
        draw_world(camera_player1, camera_player2)
        rl.end_mode_3d()
        rl.draw_rectangle(0, 0, HALF_SCREEN_WIDTH, 40, rl.fade(rl.RAYWHITE, 0.8))
        rl.draw_text("PLAYER2: UP/DOWN to move", 10, 10, 20, rl.DARKBLUE)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.draw_texture_rec(screen_player1.texture, split_screen_rect, rl.Vector2(x = 0.0, y = 0.0), rl.WHITE)
        rl.draw_texture_rec(
            screen_player2.texture,
            split_screen_rect,
            rl.Vector2(x = float<-HALF_SCREEN_WIDTH, y = 0.0),
            rl.WHITE
        )
        rl.draw_rectangle((rl.get_screen_width() / 2) - 2, 0, 4, rl.get_screen_height(), rl.LIGHTGRAY)
        rl.end_drawing()

    rl.unload_render_texture(screen_player1)
    rl.unload_render_texture(screen_player2)
    rl.close_window()
    return 0
