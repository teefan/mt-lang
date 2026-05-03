module std.raylib.runtime

import std.c.libc as libc

pub def env_flag(name: cstr) -> bool:
    let value: ptr[char]? = libc.getenv(name)
    return value != null