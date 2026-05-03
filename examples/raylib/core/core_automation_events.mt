module examples.raylib.core.core_automation_events

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - automation events"
const gravity: f32 = 400.0
const player_jump_speed: f32 = 350.0
const player_hor_speed: f32 = 200.0
const env_item_count: i32 = 5
const automation_export_path: cstr = c"automation.rae"
const automation_extensions: cstr = c".txt;.rae"

struct Player:
    position: rl.Vector2
    speed: f32
    can_jump: bool

struct EnvElement:
    rect: rl.Rectangle
    blocking: bool
    color: rl.Color

methods Player:
    edit def update(env_elements: array[EnvElement, 5], delta: f32) -> void:
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            this.position.x -= player_hor_speed * delta
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            this.position.x += player_hor_speed * delta
        if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE) and this.can_jump:
            this.speed = -player_jump_speed
            this.can_jump = false

        var hit_obstacle = false
        for index in range(0, env_item_count):
            let element = env_elements[index]
            if element.blocking:
                if element.rect.x <= this.position.x and element.rect.x + element.rect.width >= this.position.x and element.rect.y >= this.position.y and element.rect.y <= this.position.y + this.speed * delta:
                    hit_obstacle = true
                    this.speed = 0.0
                    this.position.y = element.rect.y
                    break

        if not hit_obstacle:
            this.position.y += this.speed * delta
            this.speed += gravity * delta
            this.can_jump = false
        else:
            this.can_jump = true

def screen_half(value: i32) -> f32:
    return 0.5 * value

def reset_scene(player: ref[Player], camera: ref[rl.Camera2D]) -> void:
    player.position = rl.Vector2(x = 400.0, y = 280.0)
    player.speed = 0.0
    player.can_jump = false

    camera.target = player.position
    camera.offset = rl.Vector2(x = screen_half(screen_width), y = screen_half(screen_height))
    camera.rotation = 0.0
    camera.zoom = 1.0

def update_camera(camera: ref[rl.Camera2D], player: Player, env_elements: array[EnvElement, 5]) -> void:
    camera.target = player.position
    camera.offset = rl.Vector2(x = screen_half(screen_width), y = screen_half(screen_height))

    camera.zoom += rl.GetMouseWheelMove() * 0.05
    if camera.zoom > 3.0:
        camera.zoom = 3.0
    elif camera.zoom < 0.25:
        camera.zoom = 0.25

    var min_x: f32 = 1000.0
    var min_y: f32 = 1000.0
    var max_x: f32 = -1000.0
    var max_y: f32 = -1000.0

    for index in range(0, env_item_count):
        let element = env_elements[index]
        if element.rect.x < min_x:
            min_x = element.rect.x
        if max_x < element.rect.x + element.rect.width:
            max_x = element.rect.x + element.rect.width
        if element.rect.y < min_y:
            min_y = element.rect.y
        if max_y < element.rect.y + element.rect.height:
            max_y = element.rect.y + element.rect.height

    let max_screen = rl.GetWorldToScreen2D(rl.Vector2(x = max_x, y = max_y), read(camera))
    let min_screen = rl.GetWorldToScreen2D(rl.Vector2(x = min_x, y = min_y), read(camera))

    if max_screen.x < screen_width:
        camera.offset.x = screen_width - (max_screen.x - screen_half(screen_width))
    if max_screen.y < screen_height:
        camera.offset.y = screen_height - (max_screen.y - screen_half(screen_height))
    if min_screen.x > 0.0:
        camera.offset.x = screen_half(screen_width) - min_screen.x
    if min_screen.y > 0.0:
        camera.offset.y = screen_half(screen_height) - min_screen.y

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var player = Player(
        position = rl.Vector2(x = 400.0, y = 280.0),
        speed = 0.0,
        can_jump = false,
    )
    let env_elements = array[EnvElement, 5](
        EnvElement(rect = rl.Rectangle(x = 0.0, y = 0.0, width = 1000.0, height = 400.0), blocking = false, color = rl.LIGHTGRAY),
        EnvElement(rect = rl.Rectangle(x = 0.0, y = 400.0, width = 1000.0, height = 200.0), blocking = true, color = rl.GRAY),
        EnvElement(rect = rl.Rectangle(x = 300.0, y = 200.0, width = 400.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvElement(rect = rl.Rectangle(x = 250.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
        EnvElement(rect = rl.Rectangle(x = 650.0, y = 300.0, width = 100.0, height = 10.0), blocking = true, color = rl.GRAY),
    )
    var camera = zero[rl.Camera2D]()
    reset_scene(ref_of(player), ref_of(camera))

    var aelist = zero[rl.AutomationEventList]()
    aelist = rl.LoadAutomationEventList(null)
    rl.SetAutomationEventList(ptr_of(ref_of(aelist)))

    var event_recording = false
    var event_playing = false
    var frame_counter: u32 = 0
    var play_frame_counter: u32 = 0
    var current_play_frame: u32 = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta_time: f32 = 0.015

        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()

            unsafe:
                let dropped_path = read(dropped_files.paths)
                if rl.IsFileExtension(cstr<-dropped_path, automation_extensions):
                    rl.UnloadAutomationEventList(aelist)
                    aelist = rl.LoadAutomationEventList(cstr<-dropped_path)
                    event_recording = false
                    event_playing = true
                    play_frame_counter = 0
                    current_play_frame = 0
                    reset_scene(ref_of(player), ref_of(camera))

            rl.UnloadDroppedFiles(dropped_files)

        player.update(env_elements, delta_time)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            reset_scene(ref_of(player), ref_of(camera))

        if event_playing:
            if current_play_frame >= aelist.count:
                event_playing = false
                current_play_frame = 0
                play_frame_counter = 0
            else:
                unsafe:
                    while current_play_frame < aelist.count:
                        let event = read(aelist.events + usize<-current_play_frame)
                        if play_frame_counter != event.frame:
                            break

                        rl.PlayAutomationEvent(event)
                        current_play_frame += 1

                        if current_play_frame == aelist.count:
                            event_playing = false
                            current_play_frame = 0
                            play_frame_counter = 0
                            rl.TraceLog(rl.TraceLogLevel.LOG_INFO, c"FINISH PLAYING!")
                            break

                if event_playing:
                    play_frame_counter += 1

        update_camera(ref_of(camera), player, env_elements)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_S):
            if not event_playing:
                if event_recording:
                    rl.StopAutomationEventRecording()
                    event_recording = false
                    rl.ExportAutomationEventList(aelist, automation_export_path)
                    rl.TraceLog(rl.TraceLogLevel.LOG_INFO, c"RECORDED FRAMES: %i", i32<-aelist.count)
                else:
                    rl.SetAutomationEventBaseFrame(180)
                    rl.StartAutomationEventRecording()
                    event_recording = true
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_A):
            if not event_recording and aelist.count > 0:
                event_playing = true
                play_frame_counter = 0
                current_play_frame = 0
                reset_scene(ref_of(player), ref_of(camera))

        if event_recording or event_playing:
            frame_counter += 1
        else:
            frame_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.LIGHTGRAY)
        rl.BeginMode2D(camera)

        for index in range(0, env_item_count):
            let element = env_elements[index]
            rl.DrawRectangleRec(element.rect, element.color)

        let player_rect = rl.Rectangle(x = player.position.x - 20.0, y = player.position.y - 40.0, width = 40.0, height = 40.0)
        rl.DrawRectangleRec(player_rect, rl.RED)
        rl.EndMode2D()

        rl.DrawRectangle(10, 10, 290, 145, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(10, 10, 290, 145, rl.Fade(rl.BLUE, 0.8))
        rl.DrawText(c"Controls:", 20, 20, 10, rl.BLACK)
        rl.DrawText(c"- RIGHT | LEFT: Player movement", 30, 40, 10, rl.DARKGRAY)
        rl.DrawText(c"- SPACE: Player jump", 30, 60, 10, rl.DARKGRAY)
        rl.DrawText(c"- R: Reset game state", 30, 80, 10, rl.DARKGRAY)
        rl.DrawText(c"- S: START/STOP RECORDING INPUT EVENTS", 30, 110, 10, rl.BLACK)
        rl.DrawText(c"- A: REPLAY LAST RECORDED INPUT EVENTS", 30, 130, 10, rl.BLACK)

        if event_recording:
            rl.DrawRectangle(10, 160, 290, 30, rl.Fade(rl.RED, 0.3))
            rl.DrawRectangleLines(10, 160, 290, 30, rl.Fade(rl.MAROON, 0.8))
            rl.DrawCircle(30, 175, 10.0, rl.MAROON)

            if (frame_counter / 15) % 2 == 1:
                rl.DrawText(rl.TextFormat(c"RECORDING EVENTS... [%i]", i32<-aelist.count), 50, 170, 10, rl.MAROON)
        elif event_playing:
            rl.DrawRectangle(10, 160, 290, 30, rl.Fade(rl.LIME, 0.3))
            rl.DrawRectangleLines(10, 160, 290, 30, rl.Fade(rl.DARKGREEN, 0.8))
            rl.DrawTriangle(
                rl.Vector2(x = 20, y = 165),
                rl.Vector2(x = 20, y = 185),
                rl.Vector2(x = 40, y = 175),
                rl.DARKGREEN,
            )

            if (frame_counter / 15) % 2 == 1:
                rl.DrawText(rl.TextFormat(c"PLAYING RECORDED EVENTS... [%i]", i32<-current_play_frame), 50, 170, 10, rl.DARKGREEN)

    rl.UnloadAutomationEventList(aelist)
    return 0