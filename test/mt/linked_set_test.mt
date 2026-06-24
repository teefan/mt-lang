# In-language tests for std.linked_set (migrated from
# test/std/std_linked_set_test.rb, run by `mtc test`).

import std.testing as t
import std.linked_set as linked_set

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-(read(ptr[Key]<-value).value & 1)

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value


@[test]
function test_linked_set_insertion_order_operations() -> t.Check:
    var values = linked_set.LinkedSet[Key].with_capacity(2)
    defer values.release()

    t.expect(values.capacity() >= 2, "capacity >= 2")?
    t.expect_true(values.insert(Key(value = 3)))?
    t.expect_true(values.insert(Key(value = 1)))?
    t.expect_true(values.insert(Key(value = 4)))?
    t.expect_true(values.insert(Key(value = 2)))?
    t.expect_false(values.insert(Key(value = 1)))?

    let stored = values.get(Key(value = 2))
    t.expect(stored != null, "get(2) non-null")?
    var stored_value = 0
    unsafe:
        stored_value = read(ptr[Key]<-stored).value
    t.expect_equal_int(stored_value, 2)?

    var order_ok = true
    var step = 0
    for value in values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if step == 0 and current != 3:
                order_ok = false
            if step == 1 and current != 1:
                order_ok = false
            if step == 2 and current != 4:
                order_ok = false
            if step == 3 and current != 2:
                order_ok = false
        step += 1
    t.expect_true(order_ok)?
    t.expect_equal_int(step, 4)?

    t.expect_true(values.remove(Key(value = 1)))?
    t.expect_true(values.insert(Key(value = 1)))?

    var iter_order_ok = true
    var iter = values.iter()
    var iter_step = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            let current = read(ptr[Key]<-value).value
            if iter_step == 0 and current != 3:
                iter_order_ok = false
            if iter_step == 1 and current != 4:
                iter_order_ok = false
            if iter_step == 2 and current != 2:
                iter_order_ok = false
            if iter_step == 3 and current != 1:
                iter_order_ok = false
        iter_step += 1
    t.expect_true(iter_order_ok)?
    t.expect_equal_int(iter_step, 4)?

    var other = linked_set.LinkedSet[Key].create()
    defer other.release()
    other.insert(Key(value = 2))
    other.insert(Key(value = 5))
    other.insert(Key(value = 1))

    var union_values = values.union_with(other)
    defer union_values.release()
    var union_order_ok = true
    var union_step = 0
    for value in union_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if union_step == 0 and current != 3:
                union_order_ok = false
            if union_step == 1 and current != 4:
                union_order_ok = false
            if union_step == 2 and current != 2:
                union_order_ok = false
            if union_step == 3 and current != 1:
                union_order_ok = false
            if union_step == 4 and current != 5:
                union_order_ok = false
        union_step += 1
    t.expect_true(union_order_ok)?
    t.expect_equal_int(union_step, 5)?

    var intersection_values = values.intersection(other)
    defer intersection_values.release()
    var intersection_order_ok = true
    var intersection_step = 0
    for value in intersection_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if intersection_step == 0 and current != 2:
                intersection_order_ok = false
            if intersection_step == 1 and current != 1:
                intersection_order_ok = false
        intersection_step += 1
    t.expect_true(intersection_order_ok)?
    t.expect_equal_int(intersection_step, 2)?

    var difference_values = values.difference(other)
    defer difference_values.release()
    var difference_order_ok = true
    var difference_step = 0
    for value in difference_values:
        unsafe:
            let current = read(ptr[Key]<-value).value
            if difference_step == 0 and current != 3:
                difference_order_ok = false
            if difference_step == 1 and current != 4:
                difference_order_ok = false
        difference_step += 1
    t.expect_true(difference_order_ok)?
    t.expect_equal_int(difference_step, 2)?

    var subset = linked_set.LinkedSet[Key].create()
    defer subset.release()
    subset.insert(Key(value = 3))
    subset.insert(Key(value = 1))
    t.expect_true(subset.is_subset(values))?
    t.expect_false(other.is_subset(values))?

    values.clear()
    t.expect_true(values.is_empty())?
    return t.expect(values.capacity() >= 2, "capacity retained")
