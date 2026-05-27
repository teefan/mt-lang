import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450

function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - background scrolling")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let background = rl.load_texture("cyberpunk_street_background.png")
    defer rl.unload_texture(background)
    let midground = rl.load_texture("cyberpunk_street_midground.png")
    defer rl.unload_texture(midground)
    let foreground = rl.load_texture("cyberpunk_street_foreground.png")
    defer rl.unload_texture(foreground)

    var scrolling_back = float<-0.0
    var scrolling_mid = float<-0.0
    var scrolling_fore = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        scrolling_back -= float<-0.1
        scrolling_mid -= float<-0.5
        scrolling_fore -= float<-1.0

        if scrolling_back <= -float<-(background.width * 2):
            scrolling_back = float<-0.0
        if scrolling_mid <= -float<-(midground.width * 2):
            scrolling_mid = float<-0.0
        if scrolling_fore <= -float<-(foreground.width * 2):
            scrolling_fore = float<-0.0

        rl.begin_drawing()
        rl.clear_background(rl.get_color(0x052c46ff))

        rl.draw_texture_ex(background, rl.Vector2(x = scrolling_back, y = float<-20.0), float<-0.0, float<-2.0, rl.WHITE)
        rl.draw_texture_ex(background, rl.Vector2(x = float<-(background.width * 2) + scrolling_back, y = float<-20.0), float<-0.0, float<-2.0, rl.WHITE)

        rl.draw_texture_ex(midground, rl.Vector2(x = scrolling_mid, y = float<-20.0), float<-0.0, float<-2.0, rl.WHITE)
        rl.draw_texture_ex(midground, rl.Vector2(x = float<-(midground.width * 2) + scrolling_mid, y = float<-20.0), float<-0.0, float<-2.0, rl.WHITE)

        rl.draw_texture_ex(foreground, rl.Vector2(x = scrolling_fore, y = float<-70.0), float<-0.0, float<-2.0, rl.WHITE)
        rl.draw_texture_ex(foreground, rl.Vector2(x = float<-(foreground.width * 2) + scrolling_fore, y = float<-70.0), float<-0.0, float<-2.0, rl.WHITE)

        rl.draw_text("BACKGROUND SCROLLING & PARALLAX", 10, 10, 20, rl.RED)
        rl.draw_text("(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)", SCREEN_WIDTH - 330, SCREEN_HEIGHT - 20, 10, rl.RAYWHITE)
        rl.end_drawing()

    return 0
