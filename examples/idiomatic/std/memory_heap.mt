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

    let raw = heap.alloc_bytes_aligned(size_of(Mat4), align_of(Mat4))
    if raw == null:
        heap.release(grown)
        return 3

    heap.release_bytes(raw)
    heap.release(grown)

    if not io.println("heap -> alloc[int], resize[int], alloc_bytes_aligned, release"):
        return 4

    return 0
