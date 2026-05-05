module examples.idiomatic.std.memory_arena

import std.io as io
import std.mem.arena as arena

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    var scratch = arena.create_for[Mat4](2)
    defer scratch.release()
    let capacity = scratch.remaining_bytes()

    let start = scratch.mark()
    let first = scratch.alloc[Mat4](1)
    let second = scratch.alloc[Mat4](1)
    if first == null or second == null:
        return 1
    if scratch.remaining_bytes() != 0:
        return 2

    scratch.reset(start)
    if scratch.remaining_bytes() != capacity:
        return 3

    if not io.println("arena -> create_for[Mat4], alloc[Mat4], mark/reset"):
        return 4

    return 0
