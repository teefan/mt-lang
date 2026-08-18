# In-language tests for std.stack (migrated from
# test/std/std_stack_test.rb, run by `mtc test`).

import std.stack as stack

@[test]
function test_stack_with_capacity() -> void:
    var values = stack.Stack[int].with_capacity(2)
    let cap = values.capacity()
    values.release()
    expect(cap >= 2z, "capacity should be at least 2")


@[test]
function test_stack_starts_empty() -> void:
    var values = stack.Stack[int].with_capacity(2)
    let empty = values.is_empty()
    let top_is_null = values.peek() == null
    values.release()
    expect(empty)
    expect(top_is_null)


@[test]
function test_stack_push_increases_len() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)
    let count = values.len()
    values.release()
    expect(count == 3z, "len should be 3 after three pushes")


@[test]
function test_stack_peek_returns_top() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    let top = values.peek()
    var value = 0
    if top != null:
        unsafe:
            value = read(ptr[int]<-top)
    values.release()
    expect_eq(value, 20)


@[test]
function test_stack_iteration_sums_values() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)
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
function test_stack_peek_allows_mutation() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)
    let top = values.peek() else:
        values.release()
        expect(false, "peek returned null")
        return

    unsafe:
        read(top) = 32

    var total = 0
    for value in values:
        unsafe:
            total += read(value)

    values.release()
    expect_eq(total, 62)


@[test]
function test_stack_pop_lifo_order() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)

    var first = -1
    match values.pop():
        Option.none:
            first = -1
        Option.some as payload:
            first = payload.value

    var second = -1
    match values.pop():
        Option.none:
            second = -1
        Option.some as payload:
            second = payload.value

    var third = -1
    match values.pop():
        Option.none:
            third = -1
        Option.some as payload:
            third = payload.value

    let empty = values.is_empty()
    values.release()
    expect_eq(first, 30)
    expect_eq(second, 20)
    expect_eq(third, 10)
    expect(empty)


@[test]
function test_stack_pop_empty_returns_none() -> void:
    var values = stack.Stack[int].create()
    let popped = values.pop()
    expect(popped.is_none())
    values.release()


@[test]
function test_stack_clear_empties() -> void:
    var values = stack.Stack[int].with_capacity(2)
    values.push(4)
    values.clear()
    let empty = values.is_empty()
    let top_is_null = values.peek() == null
    values.release()
    expect(empty)
    expect(top_is_null)


@[test]
function test_stack_shrink_to_fit() -> void:
    var values = stack.Stack[int].create()
    defer: values.release()
    values.push(10)
    values.push(20)
    values.reserve(128)
    expect(values.capacity() >= 128z, "capacity inflated")

    values.shrink_to_fit()
    expect(values.capacity() == 2z, "capacity == len")
    expect(values.len() == 2z, "len unchanged")

    var top = 0
    match values.pop():
        Option.some as payload:
            top = payload.value
        Option.none:
            expect(false, "pop returned none after shrink")
    expect_eq(top, 20)
