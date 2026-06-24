# In-language tests for std.stack (migrated from
# test/std/std_stack_test.rb, run by `mtc test`).

import std.testing as t
import std.stack as stack

@[test]
function test_stack_with_capacity() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    let cap = values.capacity()
    values.release()
    return t.expect(cap >= 2z, "capacity should be at least 2")


@[test]
function test_stack_starts_empty() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    let empty = values.is_empty()
    let top_is_null = values.peek() == null
    values.release()
    t.expect_true(empty)?
    return t.expect_true(top_is_null)


@[test]
function test_stack_push_increases_len() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)
    let count = values.len()
    values.release()
    return t.expect(count == 3z, "len should be 3 after three pushes")


@[test]
function test_stack_peek_returns_top() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    let top = values.peek()
    var value = 0
    if top != null:
        unsafe:
            value = read(ptr[int]<-top)
    values.release()
    return t.expect_equal_int(value, 20)


@[test]
function test_stack_iteration_sums_values() -> t.Check:
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
    t.expect_equal_int(count, 3)?
    return t.expect_equal_int(total, 60)


@[test]
function test_stack_peek_allows_mutation() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    values.push(10)
    values.push(20)
    values.push(30)
    let top = values.peek() else:
        values.release()
        return t.fail("peek returned null")

    unsafe:
        read(top) = 32

    var total = 0
    for value in values:
        unsafe:
            total += read(value)

    values.release()
    return t.expect_equal_int(total, 62)


@[test]
function test_stack_pop_lifo_order() -> t.Check:
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
    t.expect_equal_int(first, 30)?
    t.expect_equal_int(second, 20)?
    t.expect_equal_int(third, 10)?
    return t.expect_true(empty)


@[test]
function test_stack_pop_empty_returns_none() -> t.Check:
    var values = stack.Stack[int].create()
    let popped = values.pop()
    let result = t.expect_none[int](popped)
    values.release()
    return result


@[test]
function test_stack_clear_empties() -> t.Check:
    var values = stack.Stack[int].with_capacity(2)
    values.push(4)
    values.clear()
    let empty = values.is_empty()
    let top_is_null = values.peek() == null
    values.release()
    t.expect_true(empty)?
    return t.expect_true(top_is_null)
