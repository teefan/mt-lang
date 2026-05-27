import std.math as math
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const G: float = 400.0
const PLAYER_JUMP_SPD: float = 350.0
const PLAYER_HOR_SPD: float = 200.0
const ENV_ITEM_COUNT: int = 5
const CAMERA_OPTION_COUNT: int = 5
const HALF: float = 0.5
const ONE: float = 1.0
const ZERO_FLOAT: float = 0.0
const HALF_SCREEN_WIDTH: float = float<-(SCREEN_WIDTH / 2)
const HALF_SCREEN_HEIGHT: float = float<-(SCREEN_HEIGHT / 2)
const SMOOTH_MIN_SPEED: float = 30.0
const SMOOTH_MIN_EFFECT_LENGTH: float = 10.0
const SMOOTH_FRACTION_SPEED: float = 0.8
const EVEN_OUT_SPEED: float = 700.0
const MAX_ZOOM: float = 3.0
const MIN_ZOOM: float = 0.25
const ZOOM_STEP: float = 0.05
const PLAYER_HALF_WIDTH: float = 20.0
const PLAYER_HEIGHT: float = 40.0


struct Player:
    position: rl.Vector2
    speed: float
    can_jump: bool


struct EnvItem:
    rect: rl.Rectangle
    blocking: bool
    color: rl.Color


var camera_evening_out: bool = false
var camera_even_out_target: float = 0.0


function camera_description(option: int) -> str:
    if option == 0:
        return "Follow player center"
    if option == 1:
        return "Follow player center, but clamp to map edges"
    if option == 2:
        return "Follow player center; smoothed"
    if option == 3:
        return "Follow player center horizontally; update player center vertically after landing"

    return "Player push camera on getting too close to screen edge"


function update_player(player: ref[Player], env_items: array[EnvItem, ENV_ITEM_COUNT], delta: float) -> void:
    if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
        unsafe: read(player).position.x -= PLAYER_HOR_SPD * delta
    if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
        unsafe: read(player).position.x += PLAYER_HOR_SPD * delta
    let can_jump = unsafe: read(player).can_jump
    if rl.is_key_down(rl.KeyboardKey.KEY_SPACE) and can_jump:
        unsafe:
            read(player).speed = -PLAYER_JUMP_SPD
            read(player).can_jump = false

    var hit_obstacle = false
    var index = 0
    while index < ENV_ITEM_COUNT:
        let env_item = env_items[index]
        let player_position = unsafe: read(player).position
        let player_speed = unsafe: read(player).speed
        if env_item.blocking and
            env_item.rect.x <= player_position.x and
            env_item.rect.x + env_item.rect.width >= player_position.x and
            env_item.rect.y >= player_position.y and
            env_item.rect.y <= player_position.y + player_speed * delta:
            hit_obstacle = true
            unsafe:
                read(player).speed = 0.0
                read(player).position.y = env_item.rect.y
            break
        index += 1

    if not hit_obstacle:
        unsafe:
            read(player).position.y += read(player).speed * delta
            read(player).speed += G * delta
            read(player).can_jump = false
    else:
        unsafe: read(player).can_jump = true


function update_camera_center(camera: ref[rl.Camera2D], player: Player) -> void:
    unsafe:
        read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)
        read(camera).target = player.position


function update_camera_center_inside_map(camera: ref[rl.Camera2D], player: Player, env_items: array[EnvItem, ENV_ITEM_COUNT]) -> void:
    unsafe:
        read(camera).target = player.position
        read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)

    var min_x: float = 1000.0
    var min_y: float = 1000.0
    var max_x: float = -1000.0
    var max_y: float = -1000.0
    var index = 0
    while index < ENV_ITEM_COUNT:
        let env_item = env_items[index]
        if env_item.rect.x < min_x:
            min_x = env_item.rect.x
        if env_item.rect.x + env_item.rect.width > max_x:
            max_x = env_item.rect.x + env_item.rect.width
        if env_item.rect.y < min_y:
            min_y = env_item.rect.y
        if env_item.rect.y + env_item.rect.height > max_y:
            max_y = env_item.rect.y + env_item.rect.height
        index += 1

    let camera_value = unsafe: read(camera)
    let max_screen = rl.get_world_to_screen_2d(rl.Vector2(x = max_x, y = max_y), camera_value)
    let min_screen = rl.get_world_to_screen_2d(rl.Vector2(x = min_x, y = min_y), camera_value)

    if max_screen.x < float<-SCREEN_WIDTH:
        unsafe: read(camera).offset.x = float<-SCREEN_WIDTH - (max_screen.x - HALF_SCREEN_WIDTH)
    if max_screen.y < float<-SCREEN_HEIGHT:
        unsafe: read(camera).offset.y = float<-SCREEN_HEIGHT - (max_screen.y - HALF_SCREEN_HEIGHT)
    if min_screen.x > 0.0:
        unsafe: read(camera).offset.x = HALF_SCREEN_WIDTH - min_screen.x
    if min_screen.y > 0.0:
        unsafe: read(camera).offset.y = HALF_SCREEN_HEIGHT - min_screen.y


function update_camera_center_smooth_follow(camera: ref[rl.Camera2D], player: Player, delta: float) -> void:
    unsafe: read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)
    let camera_target = unsafe: read(camera).target
    let diff_x = player.position.x - camera_target.x
    let diff_y = player.position.y - camera_target.y
    let length = float<-math.sqrt(double<-(diff_x * diff_x + diff_y * diff_y))

    if length > SMOOTH_MIN_EFFECT_LENGTH:
        var speed = SMOOTH_FRACTION_SPEED * length
        if speed < SMOOTH_MIN_SPEED:
            speed = SMOOTH_MIN_SPEED
        unsafe:
            read(camera).target.x += diff_x * speed * delta / length
            read(camera).target.y += diff_y * speed * delta / length


function update_camera_even_out_on_landing(camera: ref[rl.Camera2D], player: Player, delta: float) -> void:
    unsafe:
        read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)
        read(camera).target.x = player.position.x

    if camera_evening_out:
        let camera_target_y = unsafe: read(camera).target.y
        if camera_even_out_target > camera_target_y:
            unsafe: read(camera).target.y += EVEN_OUT_SPEED * delta
            let raised_target_y = unsafe: read(camera).target.y
            if raised_target_y > camera_even_out_target:
                unsafe: read(camera).target.y = camera_even_out_target
                camera_evening_out = false
        else:
            unsafe: read(camera).target.y -= EVEN_OUT_SPEED * delta
            let lowered_target_y = unsafe: read(camera).target.y
            if lowered_target_y < camera_even_out_target:
                unsafe: read(camera).target.y = camera_even_out_target
                camera_evening_out = false
    else:
        let camera_target_y = unsafe: read(camera).target.y
        if player.can_jump and player.speed == ZERO_FLOAT and player.position.y != camera_target_y:
            camera_evening_out = true
            camera_even_out_target = player.position.y


function update_camera_player_bounds_push(camera: ref[rl.Camera2D], player: Player) -> void:
    let bbox = rl.Vector2(x = 0.2, y = 0.2)
    let camera_value = unsafe: read(camera)
    let bbox_world_min = rl.get_screen_to_world_2d(
        rl.Vector2(x = (ONE - bbox.x) * HALF * float<-SCREEN_WIDTH, y = (ONE - bbox.y) * HALF * float<-SCREEN_HEIGHT),
        camera_value,
    )
    let bbox_world_max = rl.get_screen_to_world_2d(
        rl.Vector2(x = (ONE + bbox.x) * HALF * float<-SCREEN_WIDTH, y = (ONE + bbox.y) * HALF * float<-SCREEN_HEIGHT),
        camera_value,
    )
    unsafe: read(camera).offset = rl.Vector2(x = (ONE - bbox.x) * HALF * float<-SCREEN_WIDTH, y = (ONE - bbox.y) * HALF * float<-SCREEN_HEIGHT)

    if player.position.x < bbox_world_min.x:
        unsafe: read(camera).target.x = player.position.x
    if player.position.y < bbox_world_min.y:
        unsafe: read(camera).target.y = player.position.y
    if player.position.x > bbox_world_max.x:
        unsafe: read(camera).target.x = bbox_world_min.x + (player.position.x - bbox_world_max.x)
    if player.position.y > bbox_world_max.y:
        unsafe: read(camera).target.y = bbox_world_min.y + (player.position.y - bbox_world_max.y)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 2d camera platformer")
    defer rl.close_window()

    var player = Player(position = rl.Vector2(x = 400.0, y = 280.0), speed = 0.0, can_jump = false)
    let env_items = array[EnvItem, 5](
        EnvItem(rect = rl.Rectangle(x = 0.0, y = 0.0, width = 1000.0, height = 400.0), blocking = false, color = rl.LIGHTGRAY),
        EnvItem(rect = rl.Rectangle(x = 0.0, y = 400.0, width = 1000.0, height = 200.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 300.0, y = 200.0, width = 400.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 250.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvItem(rect = rl.Rectangle(x = 650.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
    )

    var camera = rl.Camera2D(
        target = player.position,
        offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT),
        rotation = 0.0,
        zoom = 1.0,
    )

    var camera_option = 0
    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta_time = rl.get_frame_time()
        update_player(ref_of(player), env_items, delta_time)

        camera.zoom += rl.get_mouse_wheel_move() * ZOOM_STEP
        if camera.zoom > MAX_ZOOM:
            camera.zoom = MAX_ZOOM
        else if camera.zoom < MIN_ZOOM:
            camera.zoom = MIN_ZOOM

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            camera.zoom = 1.0
            player.position = rl.Vector2(x = 400.0, y = 280.0)
            player.speed = ZERO_FLOAT

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            camera_option = (camera_option + 1) % CAMERA_OPTION_COUNT

        if camera_option == 0:
            update_camera_center(ref_of(camera), player)
        else if camera_option == 1:
            update_camera_center_inside_map(ref_of(camera), player, env_items)
        else if camera_option == 2:
            update_camera_center_smooth_follow(ref_of(camera), player, delta_time)
        else if camera_option == 3:
            update_camera_even_out_on_landing(ref_of(camera), player, delta_time)
        else:
            update_camera_player_bounds_push(ref_of(camera), player)

        rl.begin_drawing()
        rl.clear_background(rl.LIGHTGRAY)

        rl.begin_mode_2d(camera)
        var index = 0
        while index < ENV_ITEM_COUNT:
            rl.draw_rectangle_rec(env_items[index].rect, env_items[index].color)
            index += 1

        let player_rect = rl.Rectangle(x = player.position.x - PLAYER_HALF_WIDTH, y = player.position.y - PLAYER_HEIGHT, width = PLAYER_HEIGHT, height = PLAYER_HEIGHT)
        rl.draw_rectangle_rec(player_rect, rl.RED)
        rl.draw_circle_v(player.position, 5.0, rl.GOLD)
        rl.end_mode_2d()

        rl.draw_text("Controls:", 20, 20, 10, rl.BLACK)
        rl.draw_text("- Right/Left to move", 40, 40, 10, rl.DARKGRAY)
        rl.draw_text("- Space to jump", 40, 60, 10, rl.DARKGRAY)
        rl.draw_text("- Mouse Wheel to Zoom in-out", 40, 80, 10, rl.DARKGRAY)
        rl.draw_text("- R to reset position + zoom", 40, 100, 10, rl.DARKGRAY)
        rl.draw_text("- C to change camera mode", 40, 120, 10, rl.DARKGRAY)
        rl.draw_text("Current camera mode:", 20, 140, 10, rl.BLACK)
        rl.draw_text(camera_description(camera_option), 40, 160, 10, rl.DARKGRAY)
        rl.end_drawing()

    return 0
