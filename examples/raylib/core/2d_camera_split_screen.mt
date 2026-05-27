import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 440
const PLAYER_SIZE: int = 40
const HALF_SCREEN_WIDTH: int = SCREEN_WIDTH / 2
const PLAYER_MOVE_SPEED: float = 3.0


function draw_scene(player1: rl.Rectangle, player2: rl.Rectangle) -> void:
    var column = 0
    while column < (SCREEN_WIDTH / PLAYER_SIZE) + 1:
        let x = PLAYER_SIZE * column
        rl.draw_line_v(rl.Vector2(x = float<-x, y = 0.0), rl.Vector2(x = float<-x, y = float<-SCREEN_HEIGHT), rl.LIGHTGRAY)
        column += 1

    var row = 0
    while row < (SCREEN_HEIGHT / PLAYER_SIZE) + 1:
        let y = PLAYER_SIZE * row
        rl.draw_line_v(rl.Vector2(x = 0.0, y = float<-y), rl.Vector2(x = float<-SCREEN_WIDTH, y = float<-y), rl.LIGHTGRAY)
        row += 1

    var cell_x = 0
    while cell_x < SCREEN_WIDTH / PLAYER_SIZE:
        var cell_y = 0
        while cell_y < SCREEN_HEIGHT / PLAYER_SIZE:
            let cell_label = rl.text_format("[%i,%i]", cell_x, cell_y)
            rl.draw_text(cell_label, 10 + PLAYER_SIZE * cell_x, 15 + PLAYER_SIZE * cell_y, 10, rl.LIGHTGRAY)
            cell_y += 1
        cell_x += 1

    rl.draw_rectangle_rec(player1, rl.RED)
    rl.draw_rectangle_rec(player2, rl.BLUE)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 2d camera split screen")

    var player1 = rl.Rectangle(x = 200.0, y = 200.0, width = float<-PLAYER_SIZE, height = float<-PLAYER_SIZE)
    var player2 = rl.Rectangle(x = 250.0, y = 200.0, width = float<-PLAYER_SIZE, height = float<-PLAYER_SIZE)

    var camera1 = rl.Camera2D(
        target = rl.Vector2(x = player1.x, y = player1.y),
        offset = rl.Vector2(x = float<-HALF_SCREEN_WIDTH, y = 200.0),
        rotation = 0.0,
        zoom = 1.0,
    )
    var camera2 = rl.Camera2D(
        target = rl.Vector2(x = player2.x, y = player2.y),
        offset = rl.Vector2(x = float<-HALF_SCREEN_WIDTH, y = 200.0),
        rotation = 0.0,
        zoom = 1.0,
    )

    let screen_camera1 = rl.load_render_texture(HALF_SCREEN_WIDTH, SCREEN_HEIGHT)
    let screen_camera2 = rl.load_render_texture(HALF_SCREEN_WIDTH, SCREEN_HEIGHT)
    let split_screen_rect = rl.Rectangle(x = 0.0, y = 0.0, width = float<-screen_camera1.texture.width, height = -float<-screen_camera1.texture.height)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_S):
            player1.y += PLAYER_MOVE_SPEED
        else if rl.is_key_down(rl.KeyboardKey.KEY_W):
            player1.y -= PLAYER_MOVE_SPEED
        if rl.is_key_down(rl.KeyboardKey.KEY_D):
            player1.x += PLAYER_MOVE_SPEED
        else if rl.is_key_down(rl.KeyboardKey.KEY_A):
            player1.x -= PLAYER_MOVE_SPEED

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            player2.y -= PLAYER_MOVE_SPEED
        else if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            player2.y += PLAYER_MOVE_SPEED
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            player2.x += PLAYER_MOVE_SPEED
        else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            player2.x -= PLAYER_MOVE_SPEED

        camera1.target = rl.Vector2(x = player1.x, y = player1.y)
        camera2.target = rl.Vector2(x = player2.x, y = player2.y)

        rl.begin_texture_mode(screen_camera1)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_2d(camera1)
        draw_scene(player1, player2)
        rl.end_mode_2d()
        rl.draw_rectangle(0, 0, HALF_SCREEN_WIDTH, 30, rl.fade(rl.RAYWHITE, 0.6))
        rl.draw_text("PLAYER1: W/S/A/D to move", 10, 10, 10, rl.MAROON)
        rl.end_texture_mode()

        rl.begin_texture_mode(screen_camera2)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_2d(camera2)
        draw_scene(player1, player2)
        rl.end_mode_2d()
        rl.draw_rectangle(0, 0, HALF_SCREEN_WIDTH, 30, rl.fade(rl.RAYWHITE, 0.6))
        rl.draw_text("PLAYER2: UP/DOWN/LEFT/RIGHT to move", 10, 10, 10, rl.DARKBLUE)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.draw_texture_rec(screen_camera1.texture, split_screen_rect, rl.Vector2(x = 0.0, y = 0.0), rl.WHITE)
        rl.draw_texture_rec(screen_camera2.texture, split_screen_rect, rl.Vector2(x = float<-HALF_SCREEN_WIDTH, y = 0.0), rl.WHITE)
        rl.draw_rectangle((rl.get_screen_width() / 2) - 2, 0, 4, rl.get_screen_height(), rl.LIGHTGRAY)
        rl.end_drawing()

    rl.unload_render_texture(screen_camera1)
    rl.unload_render_texture(screen_camera2)
    rl.close_window()
    return 0
