# In-language tests for std.binary_heap (migrated from
# test/std/std_binary_heap_test.rb, run by `mtc test`).

import std.binary_heap as binary_heap

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value


function pop_value(values: ref[binary_heap.BinaryHeap[Key]]) -> int:
    let removed = values.pop()
    match removed:
        Option.none:
            return -1
        Option.some as payload:
            return payload.value.value


@[test]
function test_binary_heap_ordered_operations() -> void:
    var values = binary_heap.BinaryHeap[Key].with_capacity(2)
    defer: values.release()

    expect(values.capacity() >= 2, "capacity >= 2")
    expect(values.is_empty())
    expect(values.peek() == null, "peek null when empty")

    values.push(Key(value = 3))
    values.push(Key(value = 1))
    values.push(Key(value = 7))
    values.push(Key(value = 7))
    values.push(Key(value = 2))

    expect(values.len() == 5, "len == 5")
    expect(values.capacity() >= 5, "capacity >= 5")

    let top = values.peek()
    expect(top != null, "peek non-null")
    var top_value = 0
    unsafe:
        top_value = read(ptr[Key]<-top).value
    expect_eq(top_value, 7)

    var iter = values.iter()
    var iter_total = 0
    var iter_count = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            iter_total += read(ptr[Key]<-value).value
        iter_count += 1
    expect_eq(iter_count, 5)
    expect_eq(iter_total, 20)

    var for_total = 0
    var for_count = 0
    for value in values:
        unsafe:
            for_total += read(ptr[Key]<-value).value
        for_count += 1
    expect_eq(for_count, 5)
    expect_eq(for_total, 20)

    expect_eq(pop_value(values), 7)
    expect_eq(pop_value(values), 7)
    expect_eq(pop_value(values), 3)
    expect_eq(pop_value(values), 2)
    expect_eq(pop_value(values), 1)
    expect(values.is_empty())
    expect(values.peek() == null, "peek null after drain")

    expect(values.pop().is_none())

    values.push(Key(value = 5))
    values.push(Key(value = 4))
    values.clear()
    expect(values.is_empty())
    expect(values.capacity() >= 5, "capacity retained")
