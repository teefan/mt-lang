import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450

enum GameScreen: int
    LOGO = 0
    TITLE = 1
    GAMEPLAY = 2
    ENDING = 3


function next_screen_requested() -> bool:
    return rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_gesture_detected(rl.Gesture.GESTURE_TAP)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - basic screen manager")
    defer rl.close_window()

    var current_screen = GameScreen.LOGO
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if current_screen == GameScreen.LOGO:
            frames_counter += 1
            if frames_counter > 120:
                current_screen = GameScreen.TITLE
        else if current_screen == GameScreen.TITLE:
            if next_screen_requested():
                current_screen = GameScreen.GAMEPLAY
        else if current_screen == GameScreen.GAMEPLAY:
            if next_screen_requested():
                current_screen = GameScreen.ENDING
        else if next_screen_requested():
            current_screen = GameScreen.TITLE

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if current_screen == GameScreen.LOGO:
            rl.draw_text("LOGO SCREEN", 20, 20, 40, rl.LIGHTGRAY)
            rl.draw_text("WAIT for 2 SECONDS...", 290, 220, 20, rl.GRAY)
        else if current_screen == GameScreen.TITLE:
            rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.GREEN)
            rl.draw_text("TITLE SCREEN", 20, 20, 40, rl.DARKGREEN)
            rl.draw_text("PRESS ENTER or TAP to JUMP to GAMEPLAY SCREEN", 120, 220, 20, rl.DARKGREEN)
        else if current_screen == GameScreen.GAMEPLAY:
            rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.PURPLE)
            rl.draw_text("GAMEPLAY SCREEN", 20, 20, 40, rl.MAROON)
            rl.draw_text("PRESS ENTER or TAP to JUMP to ENDING SCREEN", 130, 220, 20, rl.MAROON)
        else:
            rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.BLUE)
            rl.draw_text("ENDING SCREEN", 20, 20, 40, rl.DARKBLUE)
            rl.draw_text("PRESS ENTER or TAP to RETURN to TITLE SCREEN", 120, 220, 20, rl.DARKBLUE)

        rl.end_drawing()

    return 0
