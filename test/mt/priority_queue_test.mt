# In-language tests for std.priority_queue (migrated from
# test/std/std_priority_queue_test.rb, run by `mtc test`).

import std.priority_queue as priority_queue

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value


function dequeue_value(values: ref[priority_queue.PriorityQueue[Key]]) -> int:
    let removed = values.dequeue()
    match removed:
        Option.none:
            return -1
        Option.some as payload:
            return payload.value.value


@[test]
function test_priority_queue_operations() -> void:
    var values = priority_queue.PriorityQueue[Key].with_capacity(2)
    defer: values.release()

    expect(values.capacity() >= 2, "capacity >= 2")
    expect(values.is_empty())
    expect(values.peek() == null, "peek null when empty")

    values.enqueue(Key(value = 4))
    values.enqueue(Key(value = 1))
    values.enqueue(Key(value = 6))
    values.enqueue(Key(value = 2))

    expect(values.len() == 4, "len == 4")
    expect(values.capacity() >= 4, "capacity >= 4")

    let top = values.peek()
    expect(top != null, "peek non-null")
    var top_value = 0
    unsafe:
        top_value = read(ptr[Key]<-top).value
    expect_eq(top_value, 6)

    var count = 0
    var total = 0
    for value in values:
        unsafe:
            total += read(ptr[Key]<-value).value
        count += 1
    expect_eq(count, 4)
    expect_eq(total, 13)

    expect_eq(dequeue_value(values), 6)
    expect_eq(dequeue_value(values), 4)
    expect_eq(dequeue_value(values), 2)
    expect_eq(dequeue_value(values), 1)
    expect(values.is_empty())

    values.enqueue(Key(value = 3))
    values.clear()
    expect(values.is_empty())
