module examples.raylib.core.core_basic_screen_manager

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - basic screen manager"
const logo_screen_text: cstr = c"LOGO SCREEN"
const logo_wait_text: cstr = c"WAIT for 2 SECONDS..."
const title_screen_text: cstr = c"TITLE SCREEN"
const title_help_text: cstr = c"PRESS ENTER or TAP to JUMP to GAMEPLAY SCREEN"
const gameplay_screen_text: cstr = c"GAMEPLAY SCREEN"
const gameplay_help_text: cstr = c"PRESS ENTER or TAP to JUMP to ENDING SCREEN"
const ending_screen_text: cstr = c"ENDING SCREEN"
const ending_help_text: cstr = c"PRESS ENTER or TAP to RETURN to TITLE SCREEN"

enum GameScreen: i32
    LOGO = 0
    TITLE = 1
    GAMEPLAY = 2
    ENDING = 3

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var current_screen = GameScreen.LOGO
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if current_screen == GameScreen.LOGO:
            frames_counter += 1
            if frames_counter > 120:
                current_screen = GameScreen.TITLE
        elif current_screen == GameScreen.TITLE:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER) or rl.IsGestureDetected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.GAMEPLAY
        elif current_screen == GameScreen.GAMEPLAY:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER) or rl.IsGestureDetected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.ENDING
        elif current_screen == GameScreen.ENDING:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER) or rl.IsGestureDetected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.TITLE

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if current_screen == GameScreen.LOGO:
            rl.DrawText(logo_screen_text, 20, 20, 40, rl.LIGHTGRAY)
            rl.DrawText(logo_wait_text, 290, 220, 20, rl.GRAY)
        elif current_screen == GameScreen.TITLE:
            rl.DrawRectangle(0, 0, screen_width, screen_height, rl.GREEN)
            rl.DrawText(title_screen_text, 20, 20, 40, rl.DARKGREEN)
            rl.DrawText(title_help_text, 120, 220, 20, rl.DARKGREEN)
        elif current_screen == GameScreen.GAMEPLAY:
            rl.DrawRectangle(0, 0, screen_width, screen_height, rl.PURPLE)
            rl.DrawText(gameplay_screen_text, 20, 20, 40, rl.MAROON)
            rl.DrawText(gameplay_help_text, 130, 220, 20, rl.MAROON)
        elif current_screen == GameScreen.ENDING:
            rl.DrawRectangle(0, 0, screen_width, screen_height, rl.BLUE)
            rl.DrawText(ending_screen_text, 20, 20, 40, rl.DARKBLUE)
            rl.DrawText(ending_help_text, 120, 220, 20, rl.DARKBLUE)

    return 0
