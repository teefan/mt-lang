# In-language tests for std.queue (migrated from
# test/std/std_queue_test.rb, run by `mtc test`).

import std.testing as t
import std.queue as queue

@[test]
function test_queue_with_capacity_reserves() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    let result = t.expect(values.capacity() >= 2z, "capacity should be at least 2")
    values.release()
    return result


@[test]
function test_queue_starts_empty() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    let result = t.expect_true(values.is_empty())
    values.release()
    return result


@[test]
function test_queue_peek_empty_is_null() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    let result = t.expect(values.peek() == null, "peek on empty queue should be null")
    values.release()
    return result


@[test]
function test_queue_enqueue_updates_len() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)
    let result = t.expect(values.len() == 3z, "len should be 3 after three enqueues")
    values.release()
    return result


@[test]
function test_queue_iteration_sums_values() -> t.Check:
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

    t.expect_equal_int(count, 3)?
    return t.expect_equal_int(total, 60)


@[test]
function test_queue_peek_mutates_front() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(10)
    values.enqueue(20)
    values.enqueue(30)

    let front = values.peek() else:
        values.release()
        return t.fail("peek should return front pointer")
    unsafe:
        read(front) = 12

    var first = -1
    match values.dequeue():
        Option.none:
            first = -1
        Option.some as payload:
            first = payload.value

    values.release()
    return t.expect_equal_int(first, 12)


@[test]
function test_queue_dequeue_order_drains() -> t.Check:
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

    t.expect_equal_int(first, 10)?
    t.expect_equal_int(second, 20)?
    t.expect_equal_int(third, 30)?
    return t.expect_true(drained)


@[test]
function test_queue_clear_resets() -> t.Check:
    var values = queue.Queue[int].with_capacity(2)
    values.enqueue(4)
    values.clear()
    let empty = values.is_empty()
    let peek_null = values.peek() == null
    values.release()

    t.expect_true(empty)?
    return t.expect(peek_null, "peek should be null after clear")
