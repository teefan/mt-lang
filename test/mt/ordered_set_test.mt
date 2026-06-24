# In-language tests for std.ordered_set (migrated from
# test/std/std_ordered_set_test.rb, run by `mtc test`).

import std.testing as t
import std.ordered_set as ordered_set

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value


@[test]
function test_ordered_set_operations() -> t.Check:
    var values = ordered_set.OrderedSet[Key].create()
    defer values.release()

    t.expect_true(values.is_empty())?
    t.expect(values.get(Key(value = 1)) == null, "missing get null")?

    var index: int = 0
    while index < 12:
        t.expect_true(values.insert(Key(value = index)))?
        index += 1

    t.expect_false(values.insert(Key(value = 5)))?
    t.expect(values.len() == 12, "len == 12")?
    t.expect_true(values.contains(Key(value = 7)))?

    let stored = values.get(Key(value = 7))
    t.expect(stored != null, "get(7) non-null")?
    var stored_value = 0
    unsafe:
        stored_value = read(ptr[Key]<-stored).value
    t.expect_equal_int(stored_value, 7)?

    var order_ok = true
    var expected = 0
    for value in values:
        unsafe:
            if read(ptr[Key]<-value).value != expected:
                order_ok = false
        expected += 1
    t.expect_true(order_ok)?
    t.expect_equal_int(expected, 12)?

    var iter = values.iter()
    var manual_order_ok = true
    var manual_expected = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            if read(ptr[Key]<-value).value != manual_expected:
                manual_order_ok = false
        manual_expected += 1
    t.expect_true(manual_order_ok)?
    t.expect_equal_int(manual_expected, 12)?

    t.expect_true(values.remove(Key(value = 5)))?
    t.expect_true(values.remove(Key(value = 0)))?
    t.expect_true(values.remove(Key(value = 11)))?
    t.expect_false(values.remove(Key(value = 5)))?
    t.expect_false(values.contains(Key(value = 5)))?
    t.expect(values.len() == 9, "len == 9")?

    var sorted_ok = true
    var previous = -1
    var total = 0
    for value in values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if current <= previous:
                sorted_ok = false
            previous = current
            total += current
    t.expect_true(sorted_ok)?
    t.expect_equal_int(total, 50)?

    values.clear()
    t.expect_true(values.is_empty())?
    return t.expect(values.get(Key(value = 2)) == null, "cleared get null")
