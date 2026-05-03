module examples.raylib.core.core_custom_logging

import std.c.raylib as rl
import std.c.stdio as stdio
import std.c.time as ctime

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - custom logging"
const prompt_text: cstr = c"Check out the console output to see the custom logger in action!"
const time_format: cstr = c"%Y-%m-%d %H:%M:%S"

foreign def vprintf_raylib_args(format: cstr, args: rl.va_list as stdio.va_list) -> i32 = stdio.vprintf

def log_level_prefix(level: i32) -> cstr:
    if level == i32<-rl.TraceLogLevel.LOG_INFO:
        return c"[INFO] : "
    if level == i32<-rl.TraceLogLevel.LOG_ERROR:
        return c"[ERROR]: "
    if level == i32<-rl.TraceLogLevel.LOG_WARNING:
        return c"[WARN] : "
    if level == i32<-rl.TraceLogLevel.LOG_DEBUG:
        return c"[DEBUG]: "
    return c""

def custom_trace_log(level: i32, text: cstr, args: rl.va_list) -> void:
    var time_str = zero[array[char, 64]]()
    var now: ctime.time_t = 0
    now = ctime.time(ptr_of(ref_of(now)))
    let tm_info = ctime.localtime(ptr_of(ref_of(now)))

    stdio.printf(c"[")
    unsafe:
        ctime.strftime(ptr_of(ref_of(time_str[0])), 64, time_format, tm_info)
        stdio.printf(cstr<-ptr_of(ref_of(time_str[0])))
        stdio.printf(c"] ")
        stdio.printf(log_level_prefix(level))
        vprintf_raylib_args(text, args)
    stdio.printf(c"\n")

def main() -> i32:
    rl.SetTraceLogCallback(custom_trace_log)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(prompt_text, 60, 200, 20, rl.LIGHTGRAY)

    return 0