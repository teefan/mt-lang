module examples.idiomatic.raylib.srcrec_dstrec

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const scarfy_path: str = "../../raylib/resources/scarfy.png"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Texture Source/Dest")
    defer rl.close_window()

    let scarfy = rl.load_texture(scarfy_path)
    defer rl.unload_texture(scarfy)

    let frame_width = scarfy.width / 6
    let frame_height = scarfy.height

    let source_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = float<-frame_width,
        height = float<-frame_height,
    )
    let dest_rec = rl.Rectangle(
        x = float<-screen_width / 2.0,
        y = float<-screen_height / 2.0,
        width = float<-frame_width * 2.0,
        height = float<-frame_height * 2.0,
    )
    let origin = rl.Vector2(x = float<-frame_width, y = float<-frame_height)
    var rotation: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_pro(scarfy, source_rec, dest_rec, origin, rotation, rl.WHITE)

        rl.draw_line(int<-dest_rec.x, 0, int<-dest_rec.x, screen_height, rl.GRAY)
        rl.draw_line(0, int<-dest_rec.y, screen_width, int<-dest_rec.y, rl.GRAY)
        rl.draw_text("(c) Scarfy sprite by Eiden Marsal", screen_width - 200, screen_height - 20, 10, rl.GRAY)

    return 0
