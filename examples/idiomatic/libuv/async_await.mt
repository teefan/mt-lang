module examples.idiomatic.libuv.async_await

import std.async as aio


def compute_value() -> int:
    return 7


async def warmup() -> void:
    await aio.sleep(1)
    await aio.sleep(1)
    return


async def child() -> int:
    let slept = await aio.sleep(1)
    let worked = await aio.work(compute_value)
    return slept + worked


async def pipeline() -> int:
    return await child() + 35


async def app() -> int:
    await warmup()
    return await pipeline()


async def main() -> int:
    return await app()
