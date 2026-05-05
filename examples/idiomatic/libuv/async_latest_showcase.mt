module examples.idiomatic.libuv.async_latest_showcase

import std.async as aio

enum Mode: int
    a = 0
    b = 1


async def choose_mode(flag: bool) -> Mode:
    return if flag: Mode.a else: Mode.b


async def limit() -> int:
    return 3


async def idx() -> int:
    return 0


async def cond(value: int) -> bool:
    return value < 2


async def truthy() -> bool:
    return true


async def falsy() -> bool:
    return false


async def score_a() -> int:
    return 10


async def score_b() -> int:
    return 20


async def showcase() -> int:
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


async def main() -> int:
    let delay = aio.sleep(1)
    let value = showcase()
    return await delay + await value
