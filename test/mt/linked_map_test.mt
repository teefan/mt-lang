# In-language tests for std.linked_map (migrated from
# test/std/std_linked_map_test.rb, run by `mtc test`).

import std.linked_map as linked_map

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-(read(ptr[Key]<-value).value & 1)

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)


@[test]
function test_linked_map_insertion_order_operations() -> void:
    var values = linked_map.LinkedMap[Key, int].with_capacity(2)
    defer: values.release()

    expect(values.capacity() >= 2, "capacity >= 2")
    expect(values.is_empty())

    values.set(Key(value = 3), 30)
    values.set(Key(value = 1), 10)
    values.set(Key(value = 4), 40)
    values.set(Key(value = 2), 20)
    expect(values.len() == 4, "len == 4")

    var replaced_value = -1
    match values.set(Key(value = 1), 11):
        Option.none:
            expect(false, "replace returned none")
        Option.some as payload:
            replaced_value = payload.value
    expect_eq(replaced_value, 10)

    let stored_key = values.get_key(Key(value = 2))
    expect(stored_key != null, "get_key non-null")
    var stored_key_value = 0
    unsafe:
        stored_key_value = read(ptr[Key]<-stored_key).value
    expect_eq(stored_key_value, 2)

    let existing_ptr = values.get_or_insert(Key(value = 4), 99)
    var existing_value = 0
    unsafe:
        existing_value = read(existing_ptr)
        read(existing_ptr) = 41
    expect_eq(existing_value, 40)

    let inserted_ptr = values.get_or_insert(Key(value = 5), 50)
    var inserted_value = 0
    unsafe:
        inserted_value = read(inserted_ptr)
        read(inserted_ptr) = 51
    expect_eq(inserted_value, 50)

    var key_order_ok = true
    var key_step = 0
    var key_total = 0
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
            if key_step == 4 and current != 5:
                key_order_ok = false
            key_total += current
        key_step += 1
    expect(key_order_ok)
    expect_eq(key_step, 5)
    expect_eq(key_total, 15)

    var removed_key = 0
    var removed_value = 0
    match values.remove_entry(Key(value = 1)):
        Option.none:
            expect(false, "remove_entry(1) none")
        Option.some as payload:
            removed_key = payload.value.key.value
            removed_value = payload.value.value
    expect_eq(removed_key, 1)
    expect_eq(removed_value, 11)

    expect(values.set(Key(value = 1), 15).is_none())

    var entry_order_ok = true
    var entry_step = 0
    var entry_total = 0
    for entry in values:
        unsafe:
            let current_key = read(ptr[Key]<-entry.key).value
            if entry_step == 0 and current_key != 3:
                entry_order_ok = false
            if entry_step == 1 and current_key != 4:
                entry_order_ok = false
            if entry_step == 2 and current_key != 2:
                entry_order_ok = false
            if entry_step == 3 and current_key != 5:
                entry_order_ok = false
            if entry_step == 4 and current_key != 1:
                entry_order_ok = false
            entry_total += current_key
            entry_total += read(entry.value)
        entry_step += 1
    expect(entry_order_ok)
    expect_eq(entry_step, 5)
    expect_eq(entry_total, 172)

    var entries = values.entries()
    var current_total = 0
    while entries.next():
        let entry = entries.current()
        unsafe:
            current_total += read(ptr[Key]<-entry.key).value
            current_total += read(entry.value)
    expect_eq(current_total, 172)

    var removed_3 = -1
    match values.remove(Key(value = 3)):
        Option.none:
            expect(false, "remove(3) none")
        Option.some as payload:
            removed_3 = payload.value
    expect_eq(removed_3, 30)

    expect(not values.contains(Key(value = 3)))
    expect_eq(read_int(values.get(Key(value = 4))), 41)

    values.clear()
    expect(values.is_empty())
    expect(values.capacity() >= 2, "capacity retained")
