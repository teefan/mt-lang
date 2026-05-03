module examples.raylib.core.core_2d_camera_platformer

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - 2d camera platformer"
const gravity: f32 = 400.0
const player_jump_speed: f32 = 350.0
const player_hor_speed: f32 = 200.0
const env_item_count: i32 = 5
const camera_option_count: i32 = 5
const min_speed: f32 = 30.0
const min_effect_length: f32 = 10.0
const fraction_speed: f32 = 0.8
const even_out_speed: f32 = 700.0
const bbox_factor_x: f32 = 0.2
const bbox_factor_y: f32 = 0.2

struct Player:
    position: rl.Vector2
    speed: f32
    can_jump: bool

struct EnvItem:
    rect: rl.Rectangle
    blocking: bool
    color: rl.Color

struct CameraLandingState:
    evening_out: bool
    even_out_target: f32

methods Player:


    edit def update(env_items: array[EnvItem, 5], delta: f32) -> void:
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            this.position.x -= player_hor_speed * delta
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            this.position.x += player_hor_speed * delta
        if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE) and this.can_jump:
            this.speed = -player_jump_speed
            this.can_jump = false

        var hit_obstacle = false
        for index in range(0, env_item_count):
            let item = env_items[index]
            if item.blocking:
                if item.rect.x <= this.position.x and item.rect.x + item.rect.width >= this.position.x and item.rect.y >= this.position.y and item.rect.y <= this.position.y + this.speed * delta:
                    hit_obstacle = true
                    this.speed = 0.0
                    this.position.y = item.rect.y
                    break

        if not hit_obstacle:
            this.position.y += this.speed * delta
            this.speed += gravity * delta
            this.can_jump = false
        else:
            this.can_jump = true


def screen_half(value: i32) -> f32:
    return 0.5 * value


def update_camera_center(camera: ref[rl.Camera2D], player: Player, width: i32, height: i32) -> void:
    camera.offset = rl.Vector2(x = screen_half(width), y = screen_half(height))
    camera.target = player.position


def update_camera_center_inside_map(camera: ref[rl.Camera2D], player: Player, env_items: array[EnvItem, 5], width: i32, height: i32) -> void:
    let half_width = screen_half(width)
    let half_height = screen_half(height)

    camera.target = player.position
    camera.offset = rl.Vector2(x = half_width, y = half_height)

    var min_x: f32 = 1000.0
    var min_y: f32 = 1000.0
    var max_x: f32 = -1000.0
    var max_y: f32 = -1000.0

    for index in range(0, env_item_count):
        let item = env_items[index]
        if item.rect.x < min_x:
            min_x = item.rect.x
        if max_x < item.rect.x + item.rect.width:
            max_x = item.rect.x + item.rect.width
        if item.rect.y < min_y:
            min_y = item.rect.y
        if max_y < item.rect.y + item.rect.height:
            max_y = item.rect.y + item.rect.height

    let max_screen = rl.GetWorldToScreen2D(rl.Vector2(x = max_x, y = max_y), read(camera))
    let min_screen = rl.GetWorldToScreen2D(rl.Vector2(x = min_x, y = min_y), read(camera))

    if max_screen.x < width:
        camera.offset.x = width - (max_screen.x - half_width)
    if max_screen.y < height:
        camera.offset.y = height - (max_screen.y - half_height)
    if min_screen.x > 0.0:
        camera.offset.x = half_width - min_screen.x
    if min_screen.y > 0.0:
        camera.offset.y = half_height - min_screen.y


def update_camera_center_smooth_follow(camera: ref[rl.Camera2D], player: Player, delta: f32, width: i32, height: i32) -> void:
    camera.offset = rl.Vector2(x = screen_half(width), y = screen_half(height))
    let diff = player.position.subtract(camera.target)
    let length = diff.length()

    if length > min_effect_length:
        var speed = fraction_speed * length
        if speed < min_speed:
            speed = min_speed
        camera.target = camera.target.add(diff.scale(speed * delta / length))


def update_camera_even_out_on_landing(camera: ref[rl.Camera2D], player: Player, width: i32, height: i32, state: ref[CameraLandingState]) -> void:
    camera.offset = rl.Vector2(x = screen_half(width), y = screen_half(height))
    camera.target.x = player.position.x

    if state.evening_out:
        if state.even_out_target > camera.target.y:
            camera.target.y += even_out_speed * rl.GetFrameTime()
            if camera.target.y > state.even_out_target:
                camera.target.y = state.even_out_target
                state.evening_out = false
        else:
            camera.target.y -= even_out_speed * rl.GetFrameTime()
            if camera.target.y < state.even_out_target:
                camera.target.y = state.even_out_target
                state.evening_out = false
    elif player.can_jump and player.speed == 0.0 and player.position.y != camera.target.y:
        state.evening_out = true
        state.even_out_target = player.position.y


def update_camera_player_bounds_push(camera: ref[rl.Camera2D], player: Player, width: i32, height: i32) -> void:
    let bbox_world_min = rl.GetScreenToWorld2D(
        rl.Vector2(
            x = (1.0 - bbox_factor_x) * 0.5 * width,
            y = (1.0 - bbox_factor_y) * 0.5 * height,
        ),
        read(camera),
    )
    let bbox_world_max = rl.GetScreenToWorld2D(
        rl.Vector2(
            x = (1.0 + bbox_factor_x) * 0.5 * width,
            y = (1.0 + bbox_factor_y) * 0.5 * height,
        ),
        read(camera),
    )
    camera.offset = rl.Vector2(
        x = (1.0 - bbox_factor_x) * 0.5 * width,
        y = (1.0 - bbox_factor_y) * 0.5 * height,
    )

    if player.position.x < bbox_world_min.x:
        camera.target.x = player.position.x
    if player.position.y < bbox_world_min.y:
        camera.target.y = player.position.y
    if player.position.x > bbox_world_max.x:
        camera.target.x = bbox_world_min.x + (player.position.x - bbox_world_max.x)
    if player.position.y > bbox_world_max.y:
        camera.target.y = bbox_world_min.y + (player.position.y - bbox_world_max.y)


def update_camera_for_mode(camera_option: i32, camera: ref[rl.Camera2D], player: Player, env_items: array[EnvItem, 5], delta: f32, width: i32, height: i32, landing_state: ref[CameraLandingState]) -> void:
    if camera_option == 0:
        update_camera_center(camera, player, width, height)
    elif camera_option == 1:
        update_camera_center_inside_map(camera, player, env_items, width, height)
    elif camera_option == 2:
        update_camera_center_smooth_follow(camera, player, delta, width, height)
    elif camera_option == 3:
        update_camera_even_out_on_landing(camera, player, width, height, landing_state)
    else:
        update_camera_player_bounds_push(camera, player, width, height)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var player = Player(
        position = rl.Vector2(x = 400.0, y = 280.0),
        speed = 0.0,
        can_jump = false,
    )
    let env_items = array[EnvItem, 5](
        EnvItem(rect = rl.Rectangle(x = 0.0, y = 0.0, width = 1000.0, height = 400.0), blocking = false, color = rl.LIGHTGRAY),
        EnvItem(rect = rl.Rectangle(x = 0.0, y = 400.0, width = 1000.0, height = 200.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 300.0, y = 200.0, width = 400.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 250.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 650.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
    )
    var camera = rl.Camera2D(
        target = player.position,
        offset = rl.Vector2(x = screen_half(screen_width), y = screen_half(screen_height)),
        rotation = 0.0,
        zoom = 1.0,
    )
    var landing_state = CameraLandingState(evening_out = false, even_out_target = 0.0)
    var camera_option = 0
    let camera_descriptions = array[cstr, 5](
        c"Follow player center",
        c"Follow player center, but clamp to map edges",
        c"Follow player center; smoothed",
        c"Follow player center horizontally; update vertically after landing",
        c"Player pushes camera when close to screen edge",
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta_time = rl.GetFrameTime()

        player.update(env_items, delta_time)

        camera.zoom += rl.GetMouseWheelMove() * 0.05
        if camera.zoom > 3.0:
            camera.zoom = 3.0
        elif camera.zoom < 0.25:
            camera.zoom = 0.25

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            camera.zoom = 1.0
            player.position = rl.Vector2(x = 400.0, y = 280.0)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
            camera_option = (camera_option + 1) % camera_option_count

        update_camera_for_mode(camera_option, ref_of(camera), player, env_items, delta_time, screen_width, screen_height, ref_of(landing_state))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.LIGHTGRAY)
        rl.BeginMode2D(camera)
        defer rl.EndMode2D()

        for index in range(0, env_item_count):
            let item = env_items[index]
            rl.DrawRectangleRec(item.rect, item.color)

        let player_rect = rl.Rectangle(x = player.position.x - 20.0, y = player.position.y - 40.0, width = 40.0, height = 40.0)
        rl.DrawRectangleRec(player_rect, rl.RED)
        rl.DrawCircleV(player.position, 5.0, rl.GOLD)

        rl.EndMode2D()
        rl.DrawText(c"Controls:", 20, 20, 10, rl.BLACK)
        rl.DrawText(c"- Right/Left to move", 40, 40, 10, rl.DARKGRAY)
        rl.DrawText(c"- Space to jump", 40, 60, 10, rl.DARKGRAY)
        rl.DrawText(c"- Mouse Wheel to Zoom in-out", 40, 80, 10, rl.DARKGRAY)
        rl.DrawText(c"- R to reset position + zoom", 40, 100, 10, rl.DARKGRAY)
        rl.DrawText(c"- C to change camera mode", 40, 120, 10, rl.DARKGRAY)
        rl.DrawText(c"Current camera mode:", 20, 140, 10, rl.BLACK)
        rl.DrawText(camera_descriptions[camera_option], 40, 160, 10, rl.DARKGRAY)

    return 0
