## engine/async_tasks.mt — async functions with await, defer, closures, events

import std.async as aio

# ---------------------------------------------------------------------------
# Simple async leaf
# ---------------------------------------------------------------------------

public async function compute_value(input: int) -> int:
    return input * 2

# ---------------------------------------------------------------------------
# Async with await
# ---------------------------------------------------------------------------

public async function chain_computation() -> int:
    let v1 = await compute_value(5)
    let v2 = await compute_value(v1)
    return v2 + 1

# ---------------------------------------------------------------------------
# Async with defer cleanup
# ---------------------------------------------------------------------------

public async function deferred_cleanup() -> int:
    var counter: int = 0
    defer:
        counter += 1
    defer:
        counter += 2
    let v = await compute_value(3)
    return v + counter

# ---------------------------------------------------------------------------
# Async with if expression containing await
# ---------------------------------------------------------------------------

public async function conditional_await(flag: bool) -> int:
    let result = if flag: await compute_value(10) else: await compute_value(20)
    return result

# ---------------------------------------------------------------------------
# Async with await in while condition
# ---------------------------------------------------------------------------

public async function loop_with_await() -> int:
    var i: int = 0
    while (await compute_value(1)) > 0 and i < 3:
        i += 1
    return i

# ---------------------------------------------------------------------------
# Async in match discriminant
# ---------------------------------------------------------------------------

public async function match_with_await() -> int:
    let value = await compute_value(2)
    match value:
        4:
            return 10
        _:
            return 20

# ---------------------------------------------------------------------------
# Async with proc expression (captured in async context)
# ---------------------------------------------------------------------------

public async function async_with_proc() -> int:
    let offset = 5
    let cb = proc(x: int) -> int:
        return x + offset
    return cb(await compute_value(3))

# ---------------------------------------------------------------------------
# Task root functions (called from main via aio.wait)
# ---------------------------------------------------------------------------

public async function task_pipeline() -> int:
    return await chain_computation()

public async function task_with_defer() -> int:
    return await deferred_cleanup()

public async function task_with_procs() -> int:
    return await async_with_proc()
