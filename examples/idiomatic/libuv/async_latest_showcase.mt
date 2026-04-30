module examples.idiomatic.libuv.async_latest_showcase

import std.async as async

enum Mode: i32
    a = 0
    b = 1

async def choose_mode(flag: bool) -> Mode:
    return if flag then Mode.a else Mode.b

async def limit() -> i32:
    return 3

async def idx() -> i32:
    return 0

async def cond(value: i32) -> bool:
    return value < 2

async def truthy() -> bool:
    return true

async def falsy() -> bool:
    return false

async def score_a() -> i32:
    return 10

async def score_b() -> i32:
    return 20

async def showcase() -> i32:
    var total = 0
    var slots = array[i32, 1](0)

    if await truthy():
        total += 1

    while await cond(total):
        total += 1

    for i in range(0, await limit()):
        total += i

    slots[await idx()] = total
    total = slots[0]

    if await truthy() and await truthy():
        total += 1

    if await falsy() or await truthy():
        total += 1

    let branch = if await truthy() then await score_a() else await score_b()
    total += branch

    match await choose_mode(true):
        Mode.a:
            total += 1
        Mode.b:
            total += 1000

    return total

async def main() -> i32:
    let delay = async.sleep(1)
    let value = showcase()
    return await delay + await value
