import std.deque as deque
import std.async as aio

struct Payload:
    q: deque.Deque[int]

variant Wrapper:
    ok(payload: Payload)
    err(code: int)

function make_wrapper() -> Wrapper:
    return Wrapper.ok(payload = Payload(q = deque.Deque[int].create()))

async function use_match_across_await() -> int:
    match make_wrapper():
        Wrapper.ok as v:
            await aio.sleep(1)
            var payload = v.payload
            payload.q.push_back(99)
            payload.q.release()
            return 0
        Wrapper.err:
            return -1

async function main() -> int:
    var result = await use_match_across_await()
    return result
