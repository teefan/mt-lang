import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GRAVITY: float = 400.0
const PLAYER_JUMP_SPD: float = 350.0
const PLAYER_HOR_SPD: float = 200.0
const MAX_ENVIRONMENT_ELEMENTS: int = 5
const HALF_SCREEN_WIDTH: float = float<-(SCREEN_WIDTH / 2)
const HALF_SCREEN_HEIGHT: float = float<-(SCREEN_HEIGHT / 2)
const MAX_ZOOM: float = 3.0
const MIN_ZOOM: float = 0.25
const ZOOM_STEP: float = 0.05
const FIXED_DELTA_TIME: float = 0.015
const ZERO_FLOAT: float = 0.0
const PLAYER_HALF_WIDTH: float = 20.0
const PLAYER_HEIGHT: float = 40.0

struct Player:
    position: rl.Vector2
    speed: float
    can_jump: bool

struct EnvElement:
    rect: rl.Rectangle
    blocking: bool
    color: rl.Color


function reset_scene(player: ref[Player], camera: ref[rl.Camera2D]) -> void:
    unsafe:
        read(player).position = rl.Vector2(x = 400.0, y = 280.0)
        read(player).speed = ZERO_FLOAT
        read(player).can_jump = false

        read(camera).target = read(player).position
        read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)
        read(camera).rotation = 0.0
        read(camera).zoom = 1.0


function update_player(
    player: ref[Player],
    env_elements: array[EnvElement, MAX_ENVIRONMENT_ELEMENTS],
    delta_time: float
) -> void:
    if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
        unsafe: read(player).position.x -= PLAYER_HOR_SPD * delta_time
    if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
        unsafe: read(player).position.x += PLAYER_HOR_SPD * delta_time

    let can_jump = unsafe: read(player).can_jump
    if rl.is_key_down(rl.KeyboardKey.KEY_SPACE) and can_jump:
        unsafe:
            read(player).speed = -PLAYER_JUMP_SPD
            read(player).can_jump = false

    var hit_obstacle = false
    var index = 0
    while index < MAX_ENVIRONMENT_ELEMENTS:
        let element = env_elements[index]
        let player_position = unsafe: read(player).position
        let player_speed = unsafe: read(player).speed
        if (
            element.blocking
            and element.rect.x <= player_position.x
            and element.rect.x + element.rect.width >= player_position.x
            and element.rect.y >= player_position.y
            and element.rect.y <= player_position.y + player_speed * delta_time
        ):
            hit_obstacle = true
            unsafe:
                read(player).speed = ZERO_FLOAT
                read(player).position.y = element.rect.y
        index += 1

    if not hit_obstacle:
        unsafe:
            read(player).position.y += read(player).speed * delta_time
            read(player).speed += GRAVITY * delta_time
            read(player).can_jump = false
    else:
        unsafe: read(player).can_jump = true


function update_camera(
    camera: ref[rl.Camera2D],
    player: Player,
    env_elements: array[EnvElement, MAX_ENVIRONMENT_ELEMENTS]
) -> void:
    unsafe:
        read(camera).target = player.position
        read(camera).offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT)

    var min_x: float = 1000.0
    var min_y: float = 1000.0
    var max_x: float = -1000.0
    var max_y: float = -1000.0

    unsafe: read(camera).zoom += rl.get_mouse_wheel_move() * ZOOM_STEP
    let zoom = unsafe: read(camera).zoom
    if zoom > MAX_ZOOM:
        unsafe: read(camera).zoom = MAX_ZOOM
    else if zoom < MIN_ZOOM:
        unsafe: read(camera).zoom = MIN_ZOOM

    var index = 0
    while index < MAX_ENVIRONMENT_ELEMENTS:
        let element = env_elements[index]
        if element.rect.x < min_x:
            min_x = element.rect.x
        if element.rect.x + element.rect.width > max_x:
            max_x = element.rect.x + element.rect.width
        if element.rect.y < min_y:
            min_y = element.rect.y
        if element.rect.y + element.rect.height > max_y:
            max_y = element.rect.y + element.rect.height
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


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - automation events")

    var player = Player(position = rl.Vector2(x = 400.0, y = 280.0), speed = ZERO_FLOAT, can_jump = false)
    let env_elements = array[EnvElement, 5](
        EnvElement(
            rect = rl.Rectangle(x = 0.0, y = 0.0, width = 1000.0, height = 400.0),
            blocking = false,
            color = rl.LIGHTGRAY
        ),
        EnvElement(
            rect = rl.Rectangle(x = 0.0, y = 400.0, width = 1000.0, height = 200.0),
            blocking = true,
            color = rl.GRAY
        ),
        EnvElement(
            rect = rl.Rectangle(x = 300.0, y = 200.0, width = 400.0, height = 10.0),
            blocking = true,
            color = rl.GRAY
        ),
        EnvElement(
            rect = rl.Rectangle(x = 250.0, y = 300.0, width = 100.0, height = 10.0),
            blocking = true,
            color = rl.GRAY
        ),
        EnvElement(
            rect = rl.Rectangle(x = 650.0, y = 300.0, width = 100.0, height = 10.0),
            blocking = true,
            color = rl.GRAY
        )
    )
    var camera = rl.Camera2D(
        target = player.position,
        offset = rl.Vector2(x = HALF_SCREEN_WIDTH, y = HALF_SCREEN_HEIGHT),
        rotation = 0.0,
        zoom = 1.0
    )

    var aelist = rl.load_automation_event_list(null)
    rl.set_automation_event_list(ptr_of(aelist))
    var event_recording = false
    var event_playing = false
    var frame_counter: uint = 0
    var play_frame_counter: uint = 0
    var current_play_frame: ptr_uint = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            if dropped_files.count > 0:
                unsafe:
                    let raw_path = read(dropped_files.paths + ptr_uint<-0)
                    let dropped_path = text.cstr_as_str(cstr<-raw_path)
                    if rl.is_file_extension(dropped_path, ".txt;.rae"):
                        rl.unload_automation_event_list(aelist)
                        aelist = rl.load_automation_event_list(cstr<-raw_path)
                        rl.set_automation_event_list(ptr_of(aelist))

                        event_recording = false
                        event_playing = true
                        play_frame_counter = 0
                        current_play_frame = 0
                        reset_scene(ref_of(player), ref_of(camera))

        update_player(ref_of(player), env_elements, FIXED_DELTA_TIME)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            reset_scene(ref_of(player), ref_of(camera))

        if event_playing:
            while current_play_frame < ptr_uint<-aelist.count:
                let current_event = unsafe: aelist.events[current_play_frame]
                if play_frame_counter != current_event.frame:
                    break

                rl.play_automation_event(current_event)
                current_play_frame += 1

                if current_play_frame == ptr_uint<-aelist.count:
                    event_playing = false
                    current_play_frame = 0
                    play_frame_counter = 0
                    break

            play_frame_counter += 1

        update_camera(ref_of(camera), player, env_elements)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            if not event_playing:
                if event_recording:
                    rl.stop_automation_event_recording()
                    event_recording = false
                    rl.export_automation_event_list(aelist, "automation.rae")
                else:
                    rl.set_automation_event_base_frame(180)
                    rl.start_automation_event_recording()
                    event_recording = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            if not event_recording and aelist.count > 0:
                event_playing = true
                play_frame_counter = 0
                current_play_frame = 0
                reset_scene(ref_of(player), ref_of(camera))

        if event_recording or event_playing:
            frame_counter += 1
        else:
            frame_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.LIGHTGRAY)

        rl.begin_mode_2d(camera)
        var index = 0
        while index < MAX_ENVIRONMENT_ELEMENTS:
            rl.draw_rectangle_rec(env_elements[index].rect, env_elements[index].color)
            index += 1
        rl.draw_rectangle_rec(
            rl.Rectangle(
                x = player.position.x - PLAYER_HALF_WIDTH,
                y = player.position.y - PLAYER_HEIGHT,
                width = PLAYER_HEIGHT,
                height = PLAYER_HEIGHT
            ),
            rl.RED
        )
        rl.end_mode_2d()

        rl.draw_rectangle(10, 10, 290, 145, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(10, 10, 290, 145, rl.fade(rl.BLUE, 0.8))
        rl.draw_text("Controls:", 20, 20, 10, rl.BLACK)
        rl.draw_text("- RIGHT | LEFT: Player movement", 30, 40, 10, rl.DARKGRAY)
        rl.draw_text("- SPACE: Player jump", 30, 60, 10, rl.DARKGRAY)
        rl.draw_text("- R: Reset game state", 30, 80, 10, rl.DARKGRAY)
        rl.draw_text("- S: START/STOP RECORDING INPUT EVENTS", 30, 110, 10, rl.BLACK)
        rl.draw_text("- A: REPLAY LAST RECORDED INPUT EVENTS", 30, 130, 10, rl.BLACK)

        if event_recording:
            rl.draw_rectangle(10, 160, 290, 30, rl.fade(rl.RED, 0.3))
            rl.draw_rectangle_lines(10, 160, 290, 30, rl.fade(rl.MAROON, 0.8))
            rl.draw_circle(30, 175, 10.0, rl.MAROON)
            if ((frame_counter / 15) % 2) == 1:
                let recording_text = rl.text_format("RECORDING EVENTS... [%i]", int<-aelist.count)
                rl.draw_text(recording_text, 50, 170, 10, rl.MAROON)
        else if event_playing:
            rl.draw_rectangle(10, 160, 290, 30, rl.fade(rl.LIME, 0.3))
            rl.draw_rectangle_lines(10, 160, 290, 30, rl.fade(rl.DARKGREEN, 0.8))
            rl.draw_triangle(
                rl.Vector2(x = 20.0, y = 165.0),
                rl.Vector2(x = 20.0, y = 185.0),
                rl.Vector2(x = 40.0, y = 175.0),
                rl.DARKGREEN
            )
            if ((frame_counter / 15) % 2) == 1:
                let playback_text = rl.text_format("PLAYING RECORDED EVENTS... [%i]", int<-current_play_frame)
                rl.draw_text(playback_text, 50, 170, 10, rl.DARKGREEN)

        rl.end_drawing()

    rl.unload_automation_event_list(aelist)
    rl.close_window()
    return 0
