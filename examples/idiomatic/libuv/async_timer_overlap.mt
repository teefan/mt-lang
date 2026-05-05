module examples.idiomatic.libuv.async_timer_overlap

import std.async as aio
import std.libuv as uv

const overlap_delay_msec: ptr_uint = 180
const max_parallel_elapsed_ns: ulong = 300000000


async def prove_timer_overlap() -> int:
    let start_ns = uv.hrtime()
    let left = aio.sleep(overlap_delay_msec)
    let right = aio.sleep(overlap_delay_msec)
    let exit_code = await left + await right + 42
    let elapsed_ns = uv.hrtime() - start_ns
    return if elapsed_ns < max_parallel_elapsed_ns: exit_code else: 1


async def main() -> int:
    return await prove_timer_overlap()
