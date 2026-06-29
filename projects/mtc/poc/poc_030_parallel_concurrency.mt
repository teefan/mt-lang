# POC 030 — Parallel for, parallel: block, detach/gather
# Tests: parallel for (range), parallel: structured block, detach + gather
import std.async as aio

function slow_add(a: int) -> int:
    return a + 1

function main() -> int:
    var items: array[int, 4]
    items[0] = 1
    items[1] = 2
    items[2] = 3
    items[3] = 4

    parallel for i in 0..4:
        items[i] += 1

    var a: int = 0
    var b: int = 0
    parallel:
        a = 5
        b = 10

    let h1 = detach slow_add(1)
    let h2 = detach slow_add(2)
    gather h1, h2

    let _items = items
    let _a = a
    let _b = b
    return 0
