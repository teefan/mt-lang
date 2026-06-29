# POC 027 — async function + await
# Tests: async function declaration, await in expressions, Task[T] implicit
# wrapping, async call syntax, std.async.wait for sync entrypoint.
import std.async as aio

async function child() -> int:
    return 41

async function delay_demo() -> int:
    let v = await child()
    let w = if v > 40: await child() else: 0
    var i: int = 0
    while (await child()) > 0 and i < 2:
        i += 1
    return v + w + i

function main() -> int:
    let r1 = aio.wait(child())
    let r2 = aio.wait(delay_demo())
    let _r1 = r1
    let _r2 = r2
    return 0
