module examples.idiomatic.libuv.async_await

import std.async as aio


def compute_value() -> i32:
    return 7


async def warmup() -> void:
    await aio.sleep(1)
    await aio.sleep(1)
    return


async def child() -> i32:
    let slept = await aio.sleep(1)
    let worked = await aio.work(compute_value)
    return slept + worked


async def pipeline() -> i32:
    return await child() + 35


async def app() -> i32:
    await warmup()
    return await pipeline()


async def main() -> i32:
    return await app()
