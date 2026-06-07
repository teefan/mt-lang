import std.math as math
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const VIRTUAL_SCREEN_WIDTH: int = 160
const VIRTUAL_SCREEN_HEIGHT: int = 90


function trunc_float(value: float) -> float:
    if value >= 0.0:
        return float<-math.floor(double<-value)

    return float<-math.ceil(double<-value)


function main() -> int:
    let virtual_ratio = (float<-SCREEN_WIDTH) / (float<-VIRTUAL_SCREEN_WIDTH)

    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - smooth pixelperfect")
    defer rl.close_window()

    var world_space_camera = rl.Camera2D(
        offset = rl.Vector2(x = 0.0, y = 0.0),
        target = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 1.0
    )
    var screen_space_camera = rl.Camera2D(
        offset = rl.Vector2(x = 0.0, y = 0.0),
        target = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 1.0
    )

    let target = rl.load_render_texture(VIRTUAL_SCREEN_WIDTH, VIRTUAL_SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)

    let rec01 = rl.Rectangle(x = 70.0, y = 35.0, width = 20.0, height = 20.0)
    let rec02 = rl.Rectangle(x = 90.0, y = 55.0, width = 30.0, height = 10.0)
    let rec03 = rl.Rectangle(x = 80.0, y = 65.0, width = 15.0, height = 25.0)

    let source_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-target.texture.width,
        height = -(float<-target.texture.height)
    )
    let dest_rec = rl.Rectangle(
        x = -virtual_ratio,
        y = -virtual_ratio,
        width = (float<-SCREEN_WIDTH) + (virtual_ratio * 2.0),
        height = (float<-SCREEN_HEIGHT) + (virtual_ratio * 2.0)
    )
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    var rotation: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 60.0 * rl.get_frame_time()

        let camera_x = float<-(math.sin(rl.get_time()) * 50.0 - 10.0)
        let camera_y = float<-(math.cos(rl.get_time()) * 30.0)

        screen_space_camera.target = rl.Vector2(x = camera_x, y = camera_y)

        world_space_camera.target.x = trunc_float(screen_space_camera.target.x)
        screen_space_camera.target.x -= world_space_camera.target.x
        screen_space_camera.target.x *= virtual_ratio

        world_space_camera.target.y = trunc_float(screen_space_camera.target.y)
        screen_space_camera.target.y -= world_space_camera.target.y
        screen_space_camera.target.y *= virtual_ratio

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_2d(world_space_camera)
        rl.draw_rectangle_pro(rec01, origin, rotation, rl.BLACK)
        rl.draw_rectangle_pro(rec02, origin, -rotation, rl.RED)
        rl.draw_rectangle_pro(rec03, origin, rotation + 45.0, rl.BLUE)
        rl.end_mode_2d()
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RED)
        rl.begin_mode_2d(screen_space_camera)
        rl.draw_texture_pro(target.texture, source_rec, dest_rec, origin, 0.0, rl.WHITE)
        rl.end_mode_2d()

        rl.draw_text(f"Screen resolution: #{SCREEN_WIDTH}x#{SCREEN_HEIGHT}", 10, 10, 20, rl.DARKBLUE)
        rl.draw_text(f"World resolution: #{VIRTUAL_SCREEN_WIDTH}x#{VIRTUAL_SCREEN_HEIGHT}", 10, 40, 20, rl.DARKGREEN)
        rl.draw_fps(rl.get_screen_width() - 95, 10)
        rl.end_drawing()

    return 0
