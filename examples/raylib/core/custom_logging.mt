import std.raylib as rl
import std.stdio as stdio
import std.str as text
import std.time as time

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const TIMESTAMP_BUFFER_SIZE: int = 64


function log_message(level: str, message: str) -> void:
    var timestamp_buffer: array[char, TIMESTAMP_BUFFER_SIZE] = zero[array[char, TIMESTAMP_BUFFER_SIZE]]
    let now = time.now()
    unsafe: time.format_local_time_into(
        ptr_of(timestamp_buffer[0]),
        ptr_uint<-TIMESTAMP_BUFFER_SIZE,
        "%Y-%m-%d %H:%M:%S",
        now
    )
    stdio.print("[%s] [%s] : %s\n", text.chars_as_str(ptr_of(timestamp_buffer[0])), level, message)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - custom logging")
    defer rl.close_window()

    log_message("INFO", "Initialized window")
    log_message("INFO", "This port formats app-side logs because SetTraceLogCallback is not exposed in std.raylib")

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_I):
            log_message("INFO", "User triggered an info message")
        if rl.is_key_pressed(rl.KeyboardKey.KEY_W):
            log_message("WARN", "User triggered a warning message")
        if rl.is_key_pressed(rl.KeyboardKey.KEY_E):
            log_message("ERROR", "User triggered an error message")
        if rl.is_key_pressed(rl.KeyboardKey.KEY_D):
            log_message("DEBUG", "User triggered a debug message")

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text(
            "Check the console output to see the custom logger adaptation in action!",
            40,
            170,
            20,
            rl.LIGHTGRAY
        )
        rl.draw_text("I = info   W = warning   E = error   D = debug", 120, 220, 20, rl.GRAY)
        rl.draw_text(
            "This example keeps the upstream intent, but logs are generated from Milk Tea code.",
            30,
            260,
            18,
            rl.DARKGRAY
        )
        rl.end_drawing()

    return 0
