import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - srcrec dstrec")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let scarfy = rl.load_texture("scarfy.png")
    defer rl.unload_texture(scarfy)

    let frame_width = scarfy.width / 6
    let frame_height = scarfy.height

    let source_rect = rl.Rectangle(
        x = float<-0.0,
        y = float<-0.0,
        width = float<-frame_width,
        height = float<-frame_height
    )
    let dest_rect = rl.Rectangle(
        x = float<-SCREEN_WIDTH / float<-2.0,
        y = float<-SCREEN_HEIGHT / float<-2.0,
        width = float<-frame_width * float<-2.0,
        height = float<-frame_height * float<-2.0
    )
    let origin = rl.Vector2(x = float<-frame_width, y = float<-frame_height)

    var rotation = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture_pro(scarfy, source_rect, dest_rect, origin, float<-rotation, rl.WHITE)

        rl.draw_line(int<-dest_rect.x, 0, int<-dest_rect.x, SCREEN_HEIGHT, rl.GRAY)
        rl.draw_line(0, int<-dest_rect.y, SCREEN_WIDTH, int<-dest_rect.y, rl.GRAY)

        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
