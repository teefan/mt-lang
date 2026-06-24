# In-language tests for std.multiset (migrated from
# test/std/std_multiset_test.rb, run by `mtc test`).

import std.testing as t
import std.multiset as multiset

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
function test_multiset_operations() -> t.Check:
    var values = multiset.MultiSet[Key].with_capacity(2)
    defer values.release()

    t.expect(values.capacity() >= 2, "capacity >= 2")?
    t.expect_true(values.is_empty())?
    t.expect(values.len() == 0, "len == 0")?
    t.expect(values.distinct_len() == 0, "distinct_len == 0")?

    t.expect(values.insert(Key(value = 3)) == 1, "insert(3) == 1")?
    t.expect(values.add(Key(value = 1), 2) == 2, "add(1, 2) == 2")?
    t.expect(values.add(Key(value = 4), 3) == 3, "add(4, 3) == 3")?
    t.expect(values.insert(Key(value = 1)) == 3, "insert(1) == 3")?
    t.expect(values.insert(Key(value = 2)) == 1, "insert(2) == 1")?

    t.expect(values.len() == 8, "len == 8")?
    t.expect(values.total_count() == 8, "total_count == 8")?
    t.expect(values.distinct_len() == 4, "distinct_len == 4")?
    t.expect(values.count(Key(value = 1)) == 3, "count(1) == 3")?
    t.expect_true(values.contains(Key(value = 2)))?

    var value_order_ok = true
    var value_step = 0
    for value in values.values():
        unsafe:
            let current = read(ptr[Key]<-value).value
            if value_step == 0 and current != 3:
                value_order_ok = false
            if value_step == 1 and current != 1:
                value_order_ok = false
            if value_step == 2 and current != 4:
                value_order_ok = false
            if value_step == 3 and current != 2:
                value_order_ok = false
        value_step += 1
    t.expect_true(value_order_ok)?
    t.expect_equal_int(value_step, 4)?

    var entry_order_ok = true
    var entry_step = 0
    var count_total: ptr_uint = 0
    for entry in values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if entry_step == 0 and (current != 3 or entry.count != 1):
                entry_order_ok = false
            if entry_step == 1 and (current != 1 or entry.count != 3):
                entry_order_ok = false
            if entry_step == 2 and (current != 4 or entry.count != 3):
                entry_order_ok = false
            if entry_step == 3 and (current != 2 or entry.count != 1):
                entry_order_ok = false
        count_total += entry.count
        entry_step += 1
    t.expect_true(entry_order_ok)?
    t.expect_equal_int(entry_step, 4)?
    t.expect(count_total == 8, "entry counts sum == 8")?

    t.expect_true(values.remove_one(Key(value = 1)))?
    t.expect(values.count(Key(value = 1)) == 2, "count(1) == 2")?
    t.expect(values.total_count() == 7, "total_count == 7")?

    var removed_ok = false
    match values.remove_all(Key(value = 4)):
        Option.none:
            return t.fail("remove_all(4) none")
        Option.some as payload:
            removed_ok = payload.value == 3
    t.expect_true(removed_ok)?

    t.expect(values.total_count() == 4, "total_count == 4")?
    t.expect(values.distinct_len() == 3, "distinct_len == 3")?
    t.expect_false(values.remove_one(Key(value = 9)))?

    var other = multiset.MultiSet[Key].create()
    defer other.release()
    other.add(Key(value = 3), 4)
    other.add(Key(value = 1), 1)
    other.add(Key(value = 2), 1)
    other.insert(Key(value = 5))

    var union_values = values.union_with(other)
    defer union_values.release()
    var union_order_ok = true
    var union_step = 0
    for entry in union_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if union_step == 0 and (current != 3 or entry.count != 4):
                union_order_ok = false
            if union_step == 1 and (current != 1 or entry.count != 2):
                union_order_ok = false
            if union_step == 2 and (current != 2 or entry.count != 1):
                union_order_ok = false
            if union_step == 3 and (current != 5 or entry.count != 1):
                union_order_ok = false
        union_step += 1
    t.expect_true(union_order_ok)?
    t.expect_equal_int(union_step, 4)?

    var intersection_values = values.intersection(other)
    defer intersection_values.release()
    var intersection_order_ok = true
    var intersection_step = 0
    for entry in intersection_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if intersection_step == 0 and (current != 3 or entry.count != 1):
                intersection_order_ok = false
            if intersection_step == 1 and (current != 1 or entry.count != 1):
                intersection_order_ok = false
            if intersection_step == 2 and (current != 2 or entry.count != 1):
                intersection_order_ok = false
        intersection_step += 1
    t.expect_true(intersection_order_ok)?
    t.expect_equal_int(intersection_step, 3)?

    var difference_values = values.difference(other)
    defer difference_values.release()
    var difference_order_ok = true
    var difference_step = 0
    for entry in difference_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if difference_step == 0 and (current != 1 or entry.count != 1):
                difference_order_ok = false
        difference_step += 1
    t.expect_true(difference_order_ok)?
    t.expect_equal_int(difference_step, 1)?

    var combined = other.union_with(values)
    defer combined.release()
    t.expect_true(values.is_subset(combined))?
    t.expect_false(other.is_subset(values))?

    var symmetric_values = values.symmetric_difference(other)
    defer symmetric_values.release()
    var symmetric_order_ok = true
    var symmetric_step = 0
    for entry in symmetric_values:
        unsafe:
            let current = read(ptr[Key]<-entry.value).value
            if symmetric_step == 0 and (current != 3 or entry.count != 3):
                symmetric_order_ok = false
            if symmetric_step == 1 and (current != 1 or entry.count != 1):
                symmetric_order_ok = false
            if symmetric_step == 2 and (current != 5 or entry.count != 1):
                symmetric_order_ok = false
        symmetric_step += 1
    t.expect_true(symmetric_order_ok)?
    t.expect_equal_int(symmetric_step, 3)?

    values.clear()
    t.expect_true(values.is_empty())?
    t.expect(values.len() == 0, "len == 0 after clear")?
    t.expect(values.distinct_len() == 0, "distinct_len == 0 after clear")?
    return t.expect(values.capacity() >= 2, "capacity retained")
