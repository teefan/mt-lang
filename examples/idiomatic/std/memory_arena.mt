module examples.idiomatic.std.memory_arena

import std.io as io
import std.mem.arena as arena

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    let capacity = size_of(Mat4) * ptr_uint<-2
    var scratch = arena.create_aligned(capacity, align_of(Mat4))
    defer scratch.release()

    let start = scratch.mark()
    let first = arena.alloc[Mat4](ref_of(scratch), 1)
    let second = arena.alloc[Mat4](ref_of(scratch), 1)
    if first == null or second == null:
        return 1
    if scratch.remaining_bytes() != 0:
        return 2

    scratch.reset(start)
    if scratch.remaining_bytes() != capacity:
        return 3

    if not io.println("arena -> create_aligned, alloc[Mat4], mark/reset"):
        return 4

    return 0