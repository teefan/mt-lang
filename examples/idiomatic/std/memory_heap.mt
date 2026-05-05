module examples.idiomatic.std.memory_heap

import std.io as io
import std.mem.heap as heap

align(16) struct Mat4:
    data: array[float, 16]


def main() -> int:
    let items = heap.alloc[int](4)
    if items == null:
        return 1

    let grown = heap.resize(items, 8)
    if grown == null:
        heap.release(items)
        return 2

    let aligned = heap.alloc_aligned[Mat4](1)
    if aligned == null:
        heap.release(grown)
        return 3

    heap.release(aligned)
    heap.release(grown)

    if not io.println("heap -> alloc[int], resize[int], alloc_aligned[Mat4], release"):
        return 4

    return 0
