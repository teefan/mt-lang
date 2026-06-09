import std.raylib as rl
import std.raylib.debug_console as debug
import std.tracy as tracy

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 600
const TARGET_FPS: int = 60

struct GameState:
    debug: debug.DebugState
    ball_x: float
    ball_y: float
    ball_radius: float
    ball_speed_x: float
    ball_speed_y: float
    frame_count: int


function init_game() -> GameState:
    return GameState(
        debug = debug.debug_init(),
        ball_x = float<-SCREEN_WIDTH / 2.0,
        ball_y = float<-SCREEN_HEIGHT / 2.0,
        ball_radius = 15.0,
        ball_speed_x = 200.0,
        ball_speed_y = 180.0,
        frame_count = 0
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "Tracy Profiler Example")
    rl.set_target_fps(TARGET_FPS)

    var game = init_game()

    while not rl.window_should_close():
        let dt = rl.get_frame_time()
        game.frame_count = game.frame_count + 1

        let physics_zone = tracy.zone_begin(null, 1)
        tracy.plot_float("ball_x", game.ball_x)
        tracy.plot_float("ball_y", game.ball_y)

        game.ball_x = game.ball_x + game.ball_speed_x * dt
        game.ball_y = game.ball_y + game.ball_speed_y * dt

        let max_x = float<-SCREEN_WIDTH - game.ball_radius
        let max_y = float<-SCREEN_HEIGHT - game.ball_radius

        if game.ball_x < game.ball_radius:
            game.ball_x = game.ball_radius
            game.ball_speed_x = game.ball_speed_x * -1.0
        if game.ball_x > max_x:
            game.ball_x = max_x
            game.ball_speed_x = game.ball_speed_x * -1.0
        if game.ball_y < game.ball_radius:
            game.ball_y = game.ball_radius
            game.ball_speed_y = game.ball_speed_y * -1.0
        if game.ball_y > max_y:
            game.ball_y = max_y
            game.ball_speed_y = game.ball_speed_y * -1.0

        tracy.zone_end(physics_zone)

        let render_zone = tracy.zone_begin(null, 1)
        rl.begin_drawing()
        rl.clear_background(rl.Color(r = 20, g = 20, b = 30, a = 255))

        rl.draw_circle_v(
            rl.Vector2(x = game.ball_x, y = game.ball_y),
            game.ball_radius,
            rl.Color(r = 230, g = 40, b = 40, a = 255)
        )

        rl.draw_fps(10, 10)
        debug.debug_update(ref_of(game.debug))
        debug.debug_draw(const_ptr_of(game.debug), 14)

        rl.end_drawing()
        tracy.zone_end(render_zone)

        tracy.frame_mark("main_loop")

    rl.close_window()
    return 0
