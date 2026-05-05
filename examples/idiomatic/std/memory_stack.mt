module examples.idiomatic.std.memory_stack

import std.io as io
import std.mem.stack as stack

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    let capacity = size_of(Mat4) * ptr_uint<-2
    var temp = stack.create_aligned(capacity, align_of(Mat4))
    defer temp.release()

    let start = temp.mark()
    let first = stack.alloc[Mat4](ref_of(temp), 1)
    if first == null:
        return 1

    let nested = temp.mark()
    let second = stack.alloc[Mat4](ref_of(temp), 1)
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

    if not io.println("stack -> create_aligned, nested marks, reset"):
        return 6

    return 0