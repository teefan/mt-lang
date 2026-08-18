# In-language tests for std.ring_buffer

import std.ring_buffer as ring_buf


@[test]
function test_ring_buffer_push_and_pop() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    expect(b.is_empty())
    expect(not b.is_full())
    expect(b.capacity() == 4z, "capacity == 4")

    b.push(10)
    b.push(20)
    expect(b.len() == 2z, "len == 2")

    let result = b.pop()
    match result:
        Option.some as payload:
            expect_eq(payload.value, 10)
        Option.none:
            expect(false, "pop returned none")

    expect(b.len() == 1z, "len == 1 after pop")

    let result2 = b.pop()
    match result2:
        Option.some as payload:
            expect_eq(payload.value, 20)
        Option.none:
            expect(false, "pop returned none")

    expect(b.is_empty())


@[test]
function test_ring_buffer_overwrite_on_full() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(3)
    defer: b.release()

    b.push(1)
    b.push(2)
    b.push(3)
    expect(b.is_full())

    b.push(4)
    expect(b.len() == 3z, "still len == 3 after overwrite")
    expect(b.is_full())
    match b.at(0):
        Option.some as payload:
            expect_eq(payload.value, 2)
        Option.none:
            expect(false, "at(0) returned none")



@[test]
function test_ring_buffer_peek_does_not_remove() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    b.push(42)
    match b.at(0):
        Option.some as payload:
            expect_eq(payload.value, 42)
        Option.none:
            expect(false, "at(0) returned none")
    expect(b.len() == 1z, "len unchanged after peek")


@[test]
function test_ring_buffer_get_and_at_access() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    b.push(10)
    b.push(20)
    b.push(30)

    expect(b.get(3) == null, "out-of-bounds get returns null")

    match b.at(1):
        Option.some as payload:
            expect_eq(payload.value, 20)
        Option.none:
            expect(false, "at(1) returned none")

    match b.at(2):
        Option.some as payload:
            expect_eq(payload.value, 30)
        Option.none:
            expect(false, "at(2) returned none")


@[test]
function test_ring_buffer_pop_empty_returns_none() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    expect(b.peek() == null, "peek null when empty")
    expect(b.pop().is_none())


@[test]
function test_ring_buffer_clear_resets_state() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    b.push(1)
    b.push(2)
    b.clear()
    expect(b.is_empty())
    expect(b.len() == 0z, "len == 0 after clear")


@[test]
function test_ring_buffer_wraps_around_head() -> void:
    var b = ring_buf.RingBuffer[int].with_capacity(4)
    defer: b.release()

    b.push(1)
    b.push(2)
    b.push(3)
    b.pop()
    b.pop()
    b.push(4)
    b.push(5)
    b.push(6)

    expect(b.len() == 4z, "len == 4")
    match b.at(0):
        Option.some as payload:
            expect_eq(payload.value, 3)
        Option.none:
            expect(false, "at(0) returned none")
