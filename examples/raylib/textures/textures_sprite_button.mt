module examples.raylib.textures.textures_sprite_button

import std.c.raylib as rl

const num_frames: int = 3
const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - sprite button"
const button_fx_path: cstr = c"../resources/buttonfx.wav"
const button_path: cstr = c"../resources/button.png"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let fx_button = rl.LoadSound(button_fx_path)
    let button = rl.LoadTexture(button_path)

    defer:
        rl.UnloadTexture(button)
        rl.UnloadSound(fx_button)

    let frame_height = float<-button.height / float<-num_frames
    var source_rec = rl.Rectangle(x = 0.0, y = 0.0, width = float<-button.width, height = frame_height)
    let btn_bounds = rl.Rectangle(
        x = float<-screen_width / 2.0 - float<-button.width / 2.0,
        y = float<-screen_height / 2.0 - float<-button.height / float<-num_frames / 2.0,
        width = float<-button.width,
        height = frame_height,
    )

    var btn_state = 0
    var btn_action = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_point = rl.GetMousePosition()
        btn_action = false

        if rl.CheckCollisionPointRec(mouse_point, btn_bounds):
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
                btn_state = 2
            else:
                btn_state = 1

            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                btn_action = true
        else:
            btn_state = 0

        if btn_action:
            rl.PlaySound(fx_button)

        source_rec.y = float<-btn_state * frame_height

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTextureRec(button, source_rec, rl.Vector2(x = btn_bounds.x, y = btn_bounds.y), rl.WHITE)

    return 0
