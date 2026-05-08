module examples.idiomatic.libuv.async_latest_showcase

import std.async as aio

enum Mode: int
    a = 0
    b = 1


async function choose_mode(flag: bool) -> Mode:
    return if flag: Mode.a else: Mode.b


async function limit() -> int:
    return 3


async function idx() -> int:
    return 0


async function cond(value: int) -> bool:
    return value < 2


async function truthy() -> bool:
    return true


async function falsy() -> bool:
    return false


async function score_a() -> int:
    return 10


async function score_b() -> int:
    return 20


async function showcase() -> int:
    var total = 0
    var slots = array[int, 1](0)

    if await truthy():
        total += 1

    while await cond(total):
        total += 1

    for i in 0..await limit():
        total += i

    slots[await idx()] = total
    total = slots[0]

    if await truthy() and await truthy():
        total += 1

    if await falsy() or await truthy():
        total += 1

    let branch = if await truthy(): await score_a() else: await score_b()
    total += branch

    match await choose_mode(true):
        Mode.a:
            total += 1
        Mode.b:
            total += 1000

    return total


async function main() -> int:
    let delay = aio.sleep(1)
    let value = showcase()
    return await delay + await value
