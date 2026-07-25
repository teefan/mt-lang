# In-language tests for std.ring_buffer

import std.testing as t
import std.ring_buffer as ring_buf


@[test]
function test_ring_buffer_push_and_pop() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    t.expect_true(b.is_empty())?
    t.expect_false(b.is_full())?
    t.expect(b.capacity() == 4z, "capacity == 4")?

    b.push(10)
    b.push(20)
    t.expect(b.len() == 2z, "len == 2")?

    let result = b.pop()
    match result:
        Option.some as payload:
            t.expect_equal_int(payload.value, 10)?
        Option.none:
            return t.fail("pop returned none")

    t.expect(b.len() == 1z, "len == 1 after pop")?

    let result2 = b.pop()
    match result2:
        Option.some as payload:
            t.expect_equal_int(payload.value, 20)?
        Option.none:
            return t.fail("pop returned none")

    return t.expect_true(b.is_empty())


@[test]
function test_ring_buffer_overwrite_on_full() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(3)
    defer b.release()

    b.push(1)
    b.push(2)
    b.push(3)
    t.expect_true(b.is_full())?

    b.push(4)
    t.expect(b.len() == 3z, "still len == 3 after overwrite")?
    t.expect_true(b.is_full())?
    match b.at(0):
        Option.some as payload:
            t.expect_equal_int(payload.value, 2)?
        Option.none:
            return t.fail("at(0) returned none")

    return t.ok()


@[test]
function test_ring_buffer_peek_does_not_remove() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    b.push(42)
    match b.at(0):
        Option.some as payload:
            t.expect_equal_int(payload.value, 42)?
        Option.none:
            return t.fail("at(0) returned none")
    return t.expect(b.len() == 1z, "len unchanged after peek")


@[test]
function test_ring_buffer_get_and_at_access() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    b.push(10)
    b.push(20)
    b.push(30)

    t.expect(b.get(3) == null, "out-of-bounds get returns null")?

    match b.at(1):
        Option.some as payload:
            t.expect_equal_int(payload.value, 20)?
        Option.none:
            return t.fail("at(1) returned none")

    match b.at(2):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 30)
        Option.none:
            return t.fail("at(2) returned none")


@[test]
function test_ring_buffer_pop_empty_returns_none() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    t.expect(b.peek() == null, "peek null when empty")?
    return t.expect_none[int](b.pop())


@[test]
function test_ring_buffer_clear_resets_state() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    b.push(1)
    b.push(2)
    b.clear()
    t.expect_true(b.is_empty())?
    return t.expect(b.len() == 0z, "len == 0 after clear")


@[test]
function test_ring_buffer_wraps_around_head() -> t.Check:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer b.release()

    b.push(1)
    b.push(2)
    b.push(3)
    b.pop()
    b.pop()
    b.push(4)
    b.push(5)
    b.push(6)

    t.expect(b.len() == 4z, "len == 4")?
    match b.at(0):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 3)
        Option.none:
            return t.fail("at(0) returned none")
