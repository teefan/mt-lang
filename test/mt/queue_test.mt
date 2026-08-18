# In-language tests for std.queue (migrated from
# test/std/std_queue_test.rb, run by `mtc test`).

import std.queue as queue

@[test]
function test_queue_with_capacity_reserves() -> void:
    var values = queue.Queue[int].with_capacity(2)
    expect(values.capacity() >= 2z, "capacity should be at least 2")
    values.release()


@[test]
function test_queue_starts_empty() -> void:
    var values = queue.Queue[int].with_capacity(2)
    expect(values.is_empty())
    values.release()


@[test]
function test_queue_peek_empty_is_null() -> void:
    var values = queue.Queue[int].with_capacity(2)
    expect(values.peek() == null, "peek on empty queue should be null")
    values.release()


@[test]
function test_queue_enqueue_updates_len() -> void:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)
    expect(values.len() == 3z, "len should be 3 after three enqueues")
    values.release()


@[test]
function test_queue_iteration_sums_values() -> void:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)

    var total = 0
    var count = 0
    for value in values:
        unsafe:
            total += read(value)
        count += 1

    values.release()

    expect_eq(count, 3)
    expect_eq(total, 60)


@[test]
function test_queue_peek_mutates_front() -> void:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)

    let front = values.peek() else:
        values.release()
        expect(false, "peek should return front pointer")
        return
    unsafe:
        read(front) = 12

    var first = -1
    match values.dequeue():
        Option.none:
            first = -1
        Option.some as payload:
            first = payload.value

    values.release()
    expect_eq(first, 12)


@[test]
function test_queue_dequeue_order_drains() -> void:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)

    var first = -1
    match values.dequeue():
        Option.none:
            first = -1
        Option.some as payload:
            first = payload.value

    var second = -1
    match values.dequeue():
        Option.none:
            second = -1
        Option.some as payload:
            second = payload.value

    var third = -1
    match values.dequeue():
        Option.none:
            third = -1
        Option.some as payload:
            third = payload.value

    let drained = values.is_empty()
    values.release()

    expect_eq(first, 10)
    expect_eq(second, 20)
    expect_eq(third, 30)
    expect(drained)


@[test]
function test_queue_clear_resets() -> void:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(4)
    values.clear()
    let empty = values.is_empty()
    let peek_null = values.peek() == null
    values.release()

    expect(empty)
    expect(peek_null, "peek should be null after clear")


@[test]
function test_queue_shrink_to_fit() -> void:
    var values = queue.Queue[int].create()
    defer: values.release()
    values.enqueue(10)
    values.enqueue(20)
    values.reserve(128)
    expect(values.capacity() >= 128z, "capacity inflated")

    values.shrink_to_fit()
    expect(values.capacity() == 2z, "capacity == len")
    expect(values.len() == 2z, "len unchanged")

    var first = 0
    match values.dequeue():
        Option.some as payload:
            first = payload.value
        Option.none:
            expect(false, "dequeue returned none after shrink")
    expect_eq(first, 10)
