module examples.idiomatic.libuv.async_fan_out

import std.async as aio

def compute_left() -> i32:
    return 10

def compute_right() -> i32:
    return 20

async def fan_out(bonus: i32) -> i32:
    let delay = aio.sleep(1)
    let left = aio.work(compute_left)
    let right = aio.work(compute_right)
    return await delay + await left + await right + bonus

async def main() -> i32:
    let bonus = 13
    return await fan_out(bonus)