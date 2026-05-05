module examples.idiomatic.std.memory_stack

import std.io as io
import std.mem.stack as stack

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    var temp = stack.create_for[Mat4](2)
    defer temp.release()
    let capacity = temp.remaining_bytes()

    let start = temp.mark()
    let first = temp.alloc[Mat4](1)
    if first == null:
        return 1

    let nested = temp.mark()
    let second = temp.alloc[Mat4](1)
    if second == null:
        return 2
    if temp.remaining_bytes() != 0:
        return 3

    temp.reset(nested)
    if temp.remaining_bytes() != size_of(Mat4):
        return 4

    temp.reset(start)
    if temp.remaining_bytes() != capacity:
        return 5

    if not io.println("stack -> create_for[Mat4], nested marks, reset"):
        return 6

    return 0
