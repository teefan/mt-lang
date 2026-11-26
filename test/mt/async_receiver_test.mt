# Regression test for an editable async receiver: the frame stores `this`
# verbatim, so releasing the task must not free the caller-owned object.

import std.async as aio

struct Counter:
    value: int

extending Counter:
    async editable function bump(amount: int) -> int:
        this.value += amount
        return this.value

var async_counter: Counter = Counter(value = 40)

@[test]
function test_editable_async_receiver_is_not_freed() -> void:
    async_counter = Counter(value = 40)
    let body = proc(runtime: aio.Runtime) -> void:
        let task = async_counter.bump(2)
        let result = aio.wait_on(runtime, task)
        expect_eq(result, 42)
    aio.run_with_runtime(body)
    expect_eq(async_counter.value, 42)
