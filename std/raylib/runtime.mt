module std.raylib.runtime

import std.libc as libc

public function env_flag(name: str) -> bool:
    return libc.get_env(name) != null


public function require_ptr[T](value: ptr[T]?, message: str) -> ptr[T]:
    if value == null:
        fatal(message)

    return unsafe: ptr[T]<-value
