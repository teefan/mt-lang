module examples.idiomatic.libuv.async_await

import std.async as aio


function compute_value() -> int:
    return 7


async function warmup() -> void:
    await aio.sleep(1)
    await aio.sleep(1)
    return


async function child() -> int:
    let slept = await aio.sleep(1)
    let worked = await aio.work(compute_value)
    return slept + worked


async function pipeline() -> int:
    return await child() + 35


async function app() -> int:
    await warmup()
    return await pipeline()


async function main() -> int:
    return await app()
