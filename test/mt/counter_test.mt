# In-language tests for std.counter (migrated from
# test/std/std_counter_test.rb, run by `mtc test`).

import std.counter as counter

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
function test_counter_operations() -> void:
    var values = counter.Counter[Key].with_capacity(2)
    defer: values.release()

    expect(values.capacity() >= 2, "capacity >= 2")
    expect(values.is_empty())
    expect(values.count(Key(value = 3)) == 0, "count(3) == 0")

    expect(values.add(Key(value = 3), 2) == 2, "add(3, 2) == 2")
    expect(values.increment(Key(value = 1)) == 1, "increment(1) == 1")
    expect(values.add(Key(value = 4), 3) == 3, "add(4, 3) == 3")
    expect(values.increment(Key(value = 1)) == 2, "increment(1) == 2")
    expect(values.increment(Key(value = 2)) == 1, "increment(2) == 1")

    expect(values.len() == 4, "len == 4")
    expect(values.total_count() == 8, "total_count == 8")
    expect(values.count(Key(value = 4)) == 3, "count(4) == 3")
    expect(values.contains(Key(value = 2)))

    var key_order_ok = true
    var key_step = 0
    for key in values.keys():
        unsafe:
            let current = read(ptr[Key]<-key).value
            if key_step == 0 and current != 3:
                key_order_ok = false
            if key_step == 1 and current != 1:
                key_order_ok = false
            if key_step == 2 and current != 4:
                key_order_ok = false
            if key_step == 3 and current != 2:
                key_order_ok = false
        key_step += 1
    expect(key_order_ok)
    expect_eq(key_step, 4)

    var count_total: ptr_uint = 0
    for count in values.counts():
        count_total += count
    expect(count_total == 8, "counts sum == 8")

    var entry_total = 0
    for entry in values:
        unsafe:
            let current_key = read(ptr[Key]<-entry.key).value
            entry_total += current_key
            entry_total += int<-entry.count
    expect_eq(entry_total, 18)
    expect(values.total_count() == 8, "total_count still 8")

    expect(values.remove_one(Key(value = 3)))
    expect(values.count(Key(value = 3)) == 1, "count(3) == 1")
    expect(values.total_count() == 7, "total_count == 7")

    expect(values.remove_one(Key(value = 3)))
    expect(not values.contains(Key(value = 3)))
    expect(values.total_count() == 6, "total_count == 6")

    expect(values.increment(Key(value = 3)) == 1, "increment(3) == 1")

    var iter_order_ok = true
    var iter = values.entries()
    var iter_step = 0
    while iter.next():
        let entry = iter.current()
        unsafe:
            let current = read(ptr[Key]<-entry.key).value
            if iter_step == 0 and current != 1:
                iter_order_ok = false
            if iter_step == 1 and current != 4:
                iter_order_ok = false
            if iter_step == 2 and current != 2:
                iter_order_ok = false
            if iter_step == 3 and current != 3:
                iter_order_ok = false
        iter_step += 1
    expect(iter_order_ok)
    expect_eq(iter_step, 4)

    var removed_ok = false
    match values.remove(Key(value = 4)):
        Option.none:
            expect(false, "remove(4) none")
        Option.some as payload:
            removed_ok = payload.value == 3
    expect(removed_ok)

    expect(values.total_count() == 4, "total_count == 4")
    expect(not values.remove_one(Key(value = 9)))

    values.clear()
    expect(values.is_empty())
    expect(values.len() == 0, "len == 0")
    expect(values.capacity() >= 2, "capacity retained")
