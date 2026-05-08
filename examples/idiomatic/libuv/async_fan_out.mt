module examples.idiomatic.libuv.async_fan_out

import std.async as aio


function compute_left() -> int:
    return 10


function compute_right() -> int:
    return 20


async function fan_out(bonus: int) -> int:
    let delay = aio.sleep(1)
    let left = aio.work(compute_left)
    let right = aio.work(compute_right)
    return await delay + await left + await right + bonus


async function main() -> int:
    let bonus = 13
    return await fan_out(bonus)
