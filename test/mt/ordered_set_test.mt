# In-language tests for std.ordered_set (migrated from
# test/std/std_ordered_set_test.rb, run by `mtc test`).

import std.ordered_set as ordered_set

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value


@[test]
function test_ordered_set_operations() -> void:
    var values = ordered_set.OrderedSet[Key].create()
    defer: values.release()

    expect(values.is_empty())
    expect(values.get(Key(value = 1)) == null, "missing get null")

    var index: int = 0
    while index < 12:
        expect(values.insert(Key(value = index)))
        index += 1

    expect(not values.insert(Key(value = 5)))
    expect(values.len() == 12, "len == 12")
    expect(values.contains(Key(value = 7)))

    let stored = values.get(Key(value = 7))
    expect(stored != null, "get(7) non-null")
    var stored_value = 0
    unsafe:
        stored_value = read(ptr[Key]<-stored).value
    expect_eq(stored_value, 7)

    var order_ok = true
    var expected = 0
    for value in values:
        unsafe:
            if read(ptr[Key]<-value).value != expected:
                order_ok = false
        expected += 1
    expect(order_ok)
    expect_eq(expected, 12)

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
    expect(manual_order_ok)
    expect_eq(manual_expected, 12)

    expect(values.remove(Key(value = 5)))
    expect(values.remove(Key(value = 0)))
    expect(values.remove(Key(value = 11)))
    expect(not values.remove(Key(value = 5)))
    expect(not values.contains(Key(value = 5)))
    expect(values.len() == 9, "len == 9")

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
    expect(sorted_ok)
    expect_eq(total, 50)

    values.clear()
    expect(values.is_empty())
    expect(values.get(Key(value = 2)) == null, "cleared get null")
