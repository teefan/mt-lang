# In-language tests for std.ordered_map (migrated from
# test/std/std_ordered_map_test.rb, run by `mtc test`).

import std.testing as t
import std.ordered_map as ordered_map

struct Key:
    value: int

extending Key:
    static function order(left: const_ptr[Key], right: const_ptr[Key]) -> int:
        unsafe:
            return read(ptr[Key]<-left).value - read(ptr[Key]<-right).value


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)


@[test]
function test_ordered_map_operations() -> t.Check:
    var values = ordered_map.OrderedMap[Key, int].create()
    defer values.release()

    t.expect_true(values.is_empty())?
    t.expect(values.get(Key(value = 1)) == null, "missing get null")?

    t.expect_none[int](values.set(Key(value = 3), 30))?

    values.set(Key(value = 1), 10)
    values.set(Key(value = 4), 40)
    values.set(Key(value = 2), 20)

    t.expect(values.len() == 4, "len == 4")?
    t.expect_true(values.contains(Key(value = 2)))?
    t.expect_equal_int(read_int(values.get(Key(value = 4))), 40)?

    var replaced_value = -1
    match values.set(Key(value = 3), 31):
        Option.none:
            return t.fail("replace returned none")
        Option.some as payload:
            replaced_value = payload.value
    t.expect_equal_int(replaced_value, 30)?

    let stored_key = values.get_key(Key(value = 2))
    t.expect(stored_key != null, "get_key non-null")?
    var stored_key_value = 0
    unsafe:
        stored_key_value = read(ptr[Key]<-stored_key).value
    t.expect_equal_int(stored_key_value, 2)?

    var key_order_ok = true
    var expected_key = 1
    var key_sum = 0
    for key in values.keys():
        unsafe:
            let current = read(ptr[Key]<-key).value
            if current != expected_key:
                key_order_ok = false
            key_sum += current
        expected_key += 1
    t.expect_true(key_order_ok)?
    t.expect_equal_int(key_sum, 10)?

    var value_sum = 0
    for value in values.values():
        unsafe:
            if read(value) == 20:
                read(value) = 21
            value_sum += read(value)
    t.expect_equal_int(value_sum, 102)?

    var entry_total = 0
    for entry in values:
        unsafe:
            let current_key = read(ptr[Key]<-entry.key).value
            if current_key == 4:
                read(entry.value) = 41
            entry_total += current_key
            entry_total += read(entry.value)
    t.expect_equal_int(entry_total, 113)?

    var cursor_order_ok = true
    var current_total = 0
    var current_key = 1
    var entries = values.entries()
    while entries.next():
        let entry = entries.current()
        unsafe:
            let key_value = read(ptr[Key]<-entry.key).value
            if key_value != current_key:
                cursor_order_ok = false
            current_total += key_value
            current_total += read(entry.value)
        current_key += 1
    t.expect_true(cursor_order_ok)?
    t.expect_equal_int(current_total, 113)?

    let inserted_ptr = values.get_or_insert(Key(value = 5), 50)
    var inserted_value = 0
    unsafe:
        inserted_value = read(inserted_ptr)
        read(inserted_ptr) = 51
    t.expect_equal_int(inserted_value, 50)?

    let existing_ptr = values.get_or_insert(Key(value = 4), 99)
    var existing_value = 0
    unsafe:
        existing_value = read(existing_ptr)
    t.expect_equal_int(existing_value, 41)?

    var removed_key = 0
    var removed_value = 0
    match values.remove_entry(Key(value = 3)):
        Option.none:
            return t.fail("remove_entry none")
        Option.some as payload:
            removed_key = payload.value.key.value
            removed_value = payload.value.value
    t.expect_equal_int(removed_key, 3)?
    t.expect_equal_int(removed_value, 31)?

    t.expect_false(values.contains(Key(value = 3)))?
    t.expect(values.len() == 4, "len == 4 after remove_entry")?
    t.expect_equal_int(read_int(values.get(Key(value = 5))), 51)?

    var sorted_ok = true
    var previous = 0
    var total = 0
    for entry in values:
        unsafe:
            let current = read(ptr[Key]<-entry.key).value
            if current <= previous:
                sorted_ok = false
            previous = current
            total += current
            total += read(entry.value)
    t.expect_true(sorted_ok)?
    t.expect_equal_int(total, 135)?

    var removed_4 = -1
    match values.remove(Key(value = 4)):
        Option.none:
            return t.fail("remove(4) none")
        Option.some as payload:
            removed_4 = payload.value
    t.expect_equal_int(removed_4, 41)?

    t.expect_none[int](values.remove(Key(value = 3)))?

    values.clear()
    t.expect_true(values.is_empty())?
    return t.expect(values.get(Key(value = 1)) == null, "cleared get null")
