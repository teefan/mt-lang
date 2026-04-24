module std.raylib.runtime

import std.c.libc as libc
import std.c.raylib as rl

const smoke_frames_env: cstr = c"MILK_TEA_RAYLIB_SMOKE_FRAMES"
const smoke_screenshot_env: cstr = c"MILK_TEA_RAYLIB_SMOKE_SCREENSHOT"

pub def env_flag(name: cstr) -> bool:
    let value: ptr[char]? = libc.getenv(name)
    return value != null

pub def env(name: cstr, default_value: i32) -> i32:
    let value: ptr[char]? = libc.getenv(name)
    if value == null:
        return default_value

    unsafe:
        let parsed = libc.atoi(cast[cstr](value))
        if parsed > 0:
            return parsed

    return default_value

pub def smoke_capture(frame_count: i32, default_frames: i32) -> bool:
    let screenshot_path: ptr[char]? = libc.getenv(smoke_screenshot_env)
    if screenshot_path == null:
        return false
    if frame_count < env(smoke_frames_env, default_frames):
        return false

    unsafe:
        rl.TakeScreenshot(cast[cstr](screenshot_path))
    return true
