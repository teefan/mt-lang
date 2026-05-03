module examples.idiomatic.raylib.basic_screen_manager

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

enum GameScreen: i32
    LOGO = 0
    TITLE = 1
    GAMEPLAY = 2
    ENDING = 3

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Screen Manager")
    defer rl.close_window()

    var current_screen = GameScreen.LOGO
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if current_screen == GameScreen.LOGO:
            frames_counter += 1
            if frames_counter > 120:
                current_screen = GameScreen.TITLE
        elif current_screen == GameScreen.TITLE:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_gesture_detected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.GAMEPLAY
        elif current_screen == GameScreen.GAMEPLAY:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_gesture_detected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.ENDING
        elif current_screen == GameScreen.ENDING:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) or rl.is_gesture_detected(rl.Gesture.GESTURE_TAP):
                current_screen = GameScreen.TITLE

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if current_screen == GameScreen.LOGO:
            rl.draw_text("LOGO SCREEN", 20, 20, 40, rl.LIGHTGRAY)
            rl.draw_text("WAIT for 2 SECONDS...", 290, 220, 20, rl.GRAY)
        elif current_screen == GameScreen.TITLE:
            rl.draw_rectangle(0, 0, screen_width, screen_height, rl.GREEN)
            rl.draw_text("TITLE SCREEN", 20, 20, 40, rl.DARKGREEN)
            rl.draw_text("PRESS ENTER or TAP to JUMP to GAMEPLAY SCREEN", 120, 220, 20, rl.DARKGREEN)
        elif current_screen == GameScreen.GAMEPLAY:
            rl.draw_rectangle(0, 0, screen_width, screen_height, rl.PURPLE)
            rl.draw_text("GAMEPLAY SCREEN", 20, 20, 40, rl.MAROON)
            rl.draw_text("PRESS ENTER or TAP to JUMP to ENDING SCREEN", 130, 220, 20, rl.MAROON)
        elif current_screen == GameScreen.ENDING:
            rl.draw_rectangle(0, 0, screen_width, screen_height, rl.BLUE)
            rl.draw_text("ENDING SCREEN", 20, 20, 40, rl.DARKBLUE)
            rl.draw_text("PRESS ENTER or TAP to RETURN to TITLE SCREEN", 120, 220, 20, rl.DARKBLUE)

    return 0