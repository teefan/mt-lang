module examples.idiomatic.std.memory_pool

import std.io as io
import std.mem.pool as pool

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    var matrices = pool.create_for[Mat4](2)
    defer matrices.release()

    let first = matrices.alloc[Mat4]()
    let second = matrices.alloc[Mat4]()
    let third = matrices.alloc[Mat4]()
    if first == null or second == null:
        return 1
    if third != null:
        return 2
    if matrices.remaining_slots() != 0:
        return 3

    if not matrices.release_slot(first):
        return 4

    let reused = matrices.alloc[Mat4]()
    if reused == null:
        return 5
    if not matrices.release_slot(reused):
        return 6
    if not matrices.release_slot(second):
        return 7
    if matrices.remaining_slots() != 2:
        return 8

    if not io.println("pool -> create_for[Mat4], alloc[Mat4], release, reuse"):
        return 9

    return 0
