# In-language tests for std.vec (migrated from
# test/std/std_vec_test.rb, run by `mtc test`).

import std.testing as t
import std.vec as vec

struct Pair:
    left: int
    right: int


function sum(values: span[int]) -> int:
    var total = 0
    var index: ptr_uint = 0
    while index < values.len:
        unsafe:
            total += read(values.data + index)
        index += 1
    return total


@[test]
function test_vec_storage_methods() -> t.Check:
    var values = vec.Vec[int].with_capacity(1)
    defer values.release()
    t.expect(values.capacity() >= 1z, "capacity >= 1")?
    t.expect_true(values.is_empty())?
    t.expect(values.as_span().len == 0z, "empty span len 0")?

    values.push(7)
    values.push(8)
    values.push(9)
    t.expect(values.len() == 3z, "len == 3")?
    t.expect(values.capacity() >= 3z, "capacity >= 3")?
    t.expect_equal_int(sum(values.as_span()), 24)?

    var popped_value = 0
    match values.pop():
        Option.none:
            return t.fail("pop returned none")
        Option.some as payload:
            popped_value = payload.value
    t.expect_equal_int(popped_value, 9)?

    t.expect(values.len() == 2z, "len == 2")?
    values.clear()
    t.expect_true(values.is_empty())?
    t.expect(values.capacity() >= 3z, "capacity retained")?
    return t.expect_none[int](values.pop())


@[test]
function test_vec_plain_struct_elements() -> t.Check:
    var pairs = vec.Vec[Pair].create()
    defer pairs.release()
    pairs.reserve(2)
    pairs.push(Pair(left = 3, right = 4))
    pairs.push(Pair(left = 5, right = 6))
    t.expect(pairs.as_span().len == 2z, "len == 2")?

    var left = 0
    var right = 0
    match pairs.pop():
        Option.none:
            return t.fail("pop returned none")
        Option.some as payload:
            left = payload.value.left
            right = payload.value.right
    t.expect_equal_int(left, 5)?
    t.expect_equal_int(right, 6)?

    let remaining = pairs.as_span()
    t.expect(remaining.len == 1z, "len == 1")?
    var first_sum = 0
    unsafe:
        let first = read(remaining.data)
        first_sum = first.left + first.right
    return t.expect_equal_int(first_sum, 7)


@[test]
function test_vec_append_span_and_self_append() -> t.Check:
    var values = vec.Vec[int].with_capacity(2)
    defer values.release()
    var seed = array[int, 2](3, 4)
    values.append_span(span[int](data = ptr_of(seed[0]), len = 2))
    t.expect(values.len() == 2z, "len == 2 after append_span")?

    let existing = values.as_span()
    values.append_span(existing)
    t.expect(values.len() == 4z, "len == 4 after self append")?
    t.expect(values.capacity() >= 4z, "capacity >= 4")?

    let all = values.as_span()
    var ok_values = false
    unsafe:
        ok_values = read(all.data + 0) == 3 and read(all.data + 1) == 4 and read(all.data + 2) == 3 and read(all.data + 3) == 4
    return t.expect_true(ok_values)


@[test]
function test_vec_append_array_wrapper() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()
    values.append_array(array[int, 3](10, 20, 30))
    let view = values.as_span()
    t.expect(view.len == 3z, "len == 3")?
    var ok_values = false
    unsafe:
        ok_values = read(view.data + 0) == 10 and read(view.data + 1) == 20 and read(view.data + 2) == 30
    return t.expect_true(ok_values)


@[test]
function test_vec_pointer_accessors() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()
    values.push(10)
    values.push(20)
    values.push(30)

    let first = values.first()
    let middle = values.get(1)
    let last = values.last()
    t.expect(first != null and middle != null and last != null, "accessors non-null")?

    var first_value = 0
    var last_value = 0
    unsafe:
        first_value = read(ptr[int]<-first)
        last_value = read(ptr[int]<-last)
        read(ptr[int]<-middle) = 25
    t.expect_equal_int(first_value, 10)?
    t.expect_equal_int(last_value, 30)?

    var middle_after = 0
    let view = values.as_span()
    unsafe:
        middle_after = read(view.data + 1)
    t.expect_equal_int(middle_after, 25)?

    t.expect(values.get(9) == null, "out-of-range get is null")?
    t.expect(values.first() != null, "first non-null")?
    t.expect(values.last() != null, "last non-null")?

    values.clear()
    return t.expect(values.first() == null and values.last() == null, "cleared accessors null")


@[test]
function test_vec_search_helpers() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()
    values.push(10)
    values.push(20)
    values.push(30)
    values.push(40)

    let equals_thirty = proc(value: ptr[int]) -> bool:
        unsafe:
            return read(value) == 30
    let found = values.find(equals_thirty)
    t.expect(found != null, "find found 30")?
    var found_value = 0
    unsafe:
        found_value = read(ptr[int]<-found)
    t.expect_equal_int(found_value, 30)?

    t.expect(values.find(proc(value: ptr[int]) -> bool: unsafe: read(value) == 99) == null, "missing find null")?

    var index = 0z
    match values.find_index(proc(value: ptr[int]) -> bool: unsafe: read(value) == 20):
        Option.none:
            return t.fail("find_index(20) none")
        Option.some as payload:
            index = payload.value
    t.expect(index == 1z, "find_index(20) == 1")?

    match values.find_index(proc(value: ptr[int]) -> bool: unsafe: read(value) == 99):
        Option.none:
            pass
        Option.some as ignored_payload:
            return t.fail("find_index(99) should be none")

    let threshold = 25
    var any_iter = values.iter()
    t.expect_true(any_iter.any(proc(value: ptr[int]) -> bool: unsafe: read(value) > threshold))?

    var all_iter = values.iter()
    t.expect_true(all_iter.all(proc(value: ptr[int]) -> bool: unsafe: read(value) % 10 == 0))?

    var count_iter = values.iter()
    return t.expect(count_iter.count(proc(value: ptr[int]) -> bool: unsafe: read(value) >= 20) == 3z, "count >= 20 is 3")


@[test]
function test_vec_insert_and_remove() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()

    t.expect_false(values.insert(1, 50))?
    t.expect_true(values.insert(0, 10))?
    t.expect_true(values.insert(1, 30))?
    t.expect_true(values.insert(1, 20))?
    t.expect_true(values.insert(3, 40))?

    let initial = values.as_span()
    t.expect(initial.len == 4z, "len == 4")?
    var ordered = false
    unsafe:
        ordered = read(initial.data + 0) == 10 and read(initial.data + 1) == 20 and read(initial.data + 2) == 30 and read(initial.data + 3) == 40
    t.expect_true(ordered)?

    var removed_value = 0
    match values.remove(1):
        Option.none:
            return t.fail("remove(1) none")
        Option.some as payload:
            removed_value = payload.value
    t.expect_equal_int(removed_value, 20)?

    let shifted = values.as_span()
    t.expect(shifted.len == 3z, "len == 3 after remove")?
    var shifted_ok = false
    unsafe:
        shifted_ok = read(shifted.data + 0) == 10 and read(shifted.data + 1) == 30 and read(shifted.data + 2) == 40
    t.expect_true(shifted_ok)?

    var tail_value = 0
    match values.remove(2):
        Option.none:
            return t.fail("remove(2) none")
        Option.some as payload:
            tail_value = payload.value
    t.expect_equal_int(tail_value, 40)?

    return t.expect_none[int](values.remove(5))


@[test]
function test_vec_swap_remove() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()
    values.push(10)
    values.push(20)
    values.push(30)

    var removed_value = 0
    match values.swap_remove(1):
        Option.none:
            return t.fail("swap_remove(1) none")
        Option.some as payload:
            removed_value = payload.value
    t.expect_equal_int(removed_value, 20)?

    let view = values.as_span()
    t.expect(view.len == 2z, "len == 2")?
    var ok_values = false
    unsafe:
        ok_values = read(view.data + 0) == 10 and read(view.data + 1) == 30
    t.expect_true(ok_values)?

    return t.expect_none[int](values.swap_remove(5))


@[test]
function test_vec_iter_surface() -> t.Check:
    var values = vec.Vec[int].create()
    defer values.release()
    values.push(10)
    values.push(20)
    values.push(30)

    var iter = values.iter()
    let first = iter.next()
    let second = iter.next()
    let third = iter.next()
    t.expect(first != null and second != null and third != null, "three next non-null")?
    unsafe:
        read(ptr[int]<-second) = 25

    var total = 0
    for value in values:
        unsafe:
            total += read(value)
    t.expect_equal_int(total, 65)?
    return t.expect(iter.next() == null, "iter exhausted")
