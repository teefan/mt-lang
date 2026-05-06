module std.raylib.runtime

import std.libc as libc

pub def env_flag(name: str) -> bool:
    return libc.get_env(name) != null
