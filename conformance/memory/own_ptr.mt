# Spec: README.md §10 Type System

import std.mem.heap as heap

struct Thing:
    value: int

function main() -> int:
    var thing = heap.must_alloc[Thing](1)
    thing.value = 7
    let value = thing.value
    heap.release[Thing](thing)
    if value != 7:
        return 1
    return 0
