# In-language tests for std.deque (migrated from
# test/std/std_deque_test.rb, run by `mtc test`).

import std.testing as t
import std.deque as deque

struct Pair:
    left: int
    right: int


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)


@[test]
function test_deque_storage_methods() -> t.Check:
    var values = deque.Deque[int].with_capacity(1)
    defer values.release()
    t.expect(values.capacity() >= 1z, "capacity >= 1")?
    t.expect_true(values.is_empty())?

    values.push_back(10)
    values.push_back(20)
    values.push_front(5)

    t.expect(values.len() == 3z, "len == 3")?
    t.expect_equal_int(read_int(values.first()), 5)?
    t.expect_equal_int(read_int(values.get(1)), 10)?
    t.expect_equal_int(read_int(values.last()), 20)?

    let middle = values.get(1)
    t.expect(middle != null, "middle non-null")?
    unsafe:
        read(ptr[int]<-middle) = 12
    t.expect_equal_int(read_int(values.get(1)), 12)?

    var front_value = 0
    match values.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            front_value = payload.value
    t.expect_equal_int(front_value, 5)?

    var back_value = 0
    match values.pop_back():
        Option.none:
            return t.fail("pop_back none")
        Option.some as payload:
            back_value = payload.value
    t.expect_equal_int(back_value, 20)?

    var remaining_value = 0
    match values.pop_back():
        Option.none:
            return t.fail("pop_back none")
        Option.some as payload:
            remaining_value = payload.value
    t.expect_equal_int(remaining_value, 12)?

    t.expect_true(values.is_empty())?
    return t.expect_none[int](values.pop_front())


@[test]
function test_deque_wraparound_and_growth() -> t.Check:
    var values = deque.Deque[int].with_capacity(4)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)

    var dropped_value = 0
    match values.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            dropped_value = payload.value
    t.expect_equal_int(dropped_value, 10)?

    values.push_back(40)
    values.push_back(50)
    values.push_back(60)
    values.push_front(15)

    t.expect(values.len() == 6z, "len == 6")?
    t.expect(values.capacity() >= 6z, "capacity >= 6")?
    t.expect_equal_int(read_int(values.get(0)), 15)?
    t.expect_equal_int(read_int(values.get(1)), 20)?
    t.expect_equal_int(read_int(values.get(2)), 30)?
    t.expect_equal_int(read_int(values.get(3)), 40)?
    t.expect_equal_int(read_int(values.get(4)), 50)?
    t.expect_equal_int(read_int(values.get(5)), 60)?

    var front_value = 0
    match values.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            front_value = payload.value
    t.expect_equal_int(front_value, 15)?

    var back_value = 0
    match values.pop_back():
        Option.none:
            return t.fail("pop_back none")
        Option.some as payload:
            back_value = payload.value
    t.expect_equal_int(back_value, 60)?

    t.expect_equal_int(read_int(values.first()), 20)?
    return t.expect_equal_int(read_int(values.last()), 50)


@[test]
function test_deque_plain_struct_elements() -> t.Check:
    var pairs = deque.Deque[Pair].create()
    defer pairs.release()
    pairs.push_back(Pair(left = 3, right = 4))
    pairs.push_front(Pair(left = 1, right = 2))
    t.expect(pairs.len() == 2z, "len == 2")?

    let first = pairs.first()
    let last = pairs.last()
    t.expect(first != null and last != null, "first/last non-null")?
    var first_left = 0
    var first_right = 0
    var last_left = 0
    var last_right = 0
    unsafe:
        let first_pair = read(ptr[Pair]<-first)
        let last_pair = read(ptr[Pair]<-last)
        first_left = first_pair.left
        first_right = first_pair.right
        last_left = last_pair.left
        last_right = last_pair.right
    t.expect(first_left == 1 and first_right == 2, "front pair == (1, 2)")?
    t.expect(last_left == 3 and last_right == 4, "back pair == (3, 4)")?

    var front_ok = false
    match pairs.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            front_ok = payload.value.left == 1 and payload.value.right == 2
    t.expect_true(front_ok)?

    var back_ok = false
    match pairs.pop_back():
        Option.none:
            return t.fail("pop_back none")
        Option.some as payload:
            back_ok = payload.value.left == 3 and payload.value.right == 4
    return t.expect_true(back_ok)


@[test]
function test_deque_insert_and_remove() -> t.Check:
    var values = deque.Deque[int].with_capacity(6)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)
    values.push_back(40)

    var dropped_value = 0
    match values.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            dropped_value = payload.value
    t.expect_equal_int(dropped_value, 10)?

    values.push_back(50)
    values.push_back(60)

    t.expect_true(values.insert(1, 25))?
    t.expect_true(values.insert(5, 55))?
    t.expect_false(values.insert(20, 99))?

    t.expect(values.len() == 7z, "len == 7")?
    t.expect_equal_int(read_int(values.get(0)), 20)?
    t.expect_equal_int(read_int(values.get(1)), 25)?
    t.expect_equal_int(read_int(values.get(2)), 30)?
    t.expect_equal_int(read_int(values.get(3)), 40)?
    t.expect_equal_int(read_int(values.get(4)), 50)?
    t.expect_equal_int(read_int(values.get(5)), 55)?
    t.expect_equal_int(read_int(values.get(6)), 60)?

    var removed_front_half = 0
    match values.remove(1):
        Option.none:
            return t.fail("remove(1) none")
        Option.some as payload:
            removed_front_half = payload.value
    t.expect_equal_int(removed_front_half, 25)?

    var removed_back_half = 0
    match values.remove(4):
        Option.none:
            return t.fail("remove(4) none")
        Option.some as payload:
            removed_back_half = payload.value
    t.expect_equal_int(removed_back_half, 55)?

    return t.expect_none[int](values.remove(10))


@[test]
function test_deque_rotations() -> t.Check:
    var values = deque.Deque[int].with_capacity(5)
    defer values.release()

    values.push_back(10)
    values.push_back(20)
    values.push_back(30)
    values.push_back(40)

    var first_value = 0
    match values.pop_front():
        Option.none:
            return t.fail("pop_front none")
        Option.some as payload:
            first_value = payload.value
    t.expect_equal_int(first_value, 10)?

    values.push_back(50)
    values.push_back(60)

    values.rotate_left(7)
    t.expect_equal_int(read_int(values.get(0)), 40)?
    t.expect_equal_int(read_int(values.get(1)), 50)?
    t.expect_equal_int(read_int(values.get(2)), 60)?
    t.expect_equal_int(read_int(values.get(3)), 20)?
    t.expect_equal_int(read_int(values.get(4)), 30)?

    values.rotate_right(11)
    t.expect_equal_int(read_int(values.get(0)), 30)?
    t.expect_equal_int(read_int(values.get(1)), 40)?
    t.expect_equal_int(read_int(values.get(2)), 50)?
    t.expect_equal_int(read_int(values.get(3)), 60)?
    t.expect_equal_int(read_int(values.get(4)), 20)?

    t.expect_equal_int(read_int(values.first()), 30)?
    return t.expect_equal_int(read_int(values.last()), 20)


@[test]
function test_deque_iter_surface() -> t.Check:
    var values = deque.Deque[int].create()
    defer values.release()
    values.push_back(10)
    values.push_back(20)
    values.push_front(5)

    var iter = values.iter()
    let first = iter.next()
    let second = iter.next()
    let third = iter.next()
    t.expect(first != null and second != null and third != null, "three next non-null")?
    var seq_ok = false
    unsafe:
        seq_ok = read(ptr[int]<-first) == 5 and read(ptr[int]<-second) == 10 and read(ptr[int]<-third) == 20
        read(ptr[int]<-second) = 12
    t.expect_true(seq_ok)?

    var total = 0
    for value in values:
        unsafe:
            total += read(value)
    t.expect_equal_int(total, 37)?
    return t.expect(iter.next() == null, "iter exhausted")
