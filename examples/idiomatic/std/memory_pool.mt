module examples.idiomatic.std.memory_pool

import std.io as io
import std.mem.pool as pool

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    var matrices = pool.create_for[Mat4](2)
    defer matrices.release()

    let first = pool.alloc[Mat4](ref_of(matrices))
    let second = pool.alloc[Mat4](ref_of(matrices))
    let third = pool.alloc[Mat4](ref_of(matrices))
    if first == null or second == null:
        return 1
    if third != null:
        return 2
    if matrices.remaining_slots() != 0:
        return 3

    if not pool.release[Mat4](ref_of(matrices), first):
        return 4

    let reused = pool.alloc[Mat4](ref_of(matrices))
    if reused == null:
        return 5
    if not pool.release[Mat4](ref_of(matrices), reused):
        return 6
    if not pool.release[Mat4](ref_of(matrices), second):
        return 7
    if matrices.remaining_slots() != 2:
        return 8

    if not io.println("pool -> create_for, alloc, release, reuse"):
        return 9

    return 0
