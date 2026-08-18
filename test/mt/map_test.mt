# In-language tests for std.map (migrated from
# test/std/std_map_test.rb, run by `mtc test`).

import std.map as map

struct Key:
    value: int

extending Key:
    static function hash(value: const_ptr[Key]) -> uint:
        unsafe:
            return uint<-read(ptr[Key]<-value).value

    static function equal(left: const_ptr[Key], right: const_ptr[Key]) -> bool:
        unsafe:
            return read(ptr[Key]<-left).value == read(ptr[Key]<-right).value


struct CollisionKey:
    value: int

extending CollisionKey:
    static function hash(value: const_ptr[CollisionKey]) -> uint:
        unsafe:
            return uint<-(read(ptr[CollisionKey]<-value).value & 1)

    static function equal(left: const_ptr[CollisionKey], right: const_ptr[CollisionKey]) -> bool:
        unsafe:
            return read(ptr[CollisionKey]<-left).value == read(ptr[CollisionKey]<-right).value


function read_int(value: ptr[int]?) -> int:
    if value == null:
        return -1
    unsafe:
        return read(ptr[int]<-value)


@[test]
function test_map_basic_operations() -> void:
    var values = map.Map[Key, int].with_capacity(4)
    defer: values.release()

    let first_key = Key(value = 1)
    let second_key = Key(value = 2)

    expect(values.capacity() >= 4z, "capacity >= 4")
    expect(values.is_empty())
    expect(values.get(first_key) == null, "missing get null")

    expect(values.set(first_key, 10).is_none())

    expect(values.len() == 1z, "len == 1")
    expect(values.contains(first_key))
    expect_eq(read_int(values.get(first_key)), 10)

    var replaced_value = -1
    match values.set(first_key, 15):
        Option.none:
            expect(false, "replace returned none")
        Option.some as payload:
            replaced_value = payload.value
    expect_eq(replaced_value, 10)
    expect_eq(read_int(values.get(first_key)), 15)

    expect(values.set(second_key, 20).is_none())
    expect(values.len() == 2z, "len == 2")
    expect_eq(read_int(values.get(second_key)), 20)

    var removed_value = -1
    match values.remove(first_key):
        Option.none:
            expect(false, "remove returned none")
        Option.some as payload:
            removed_value = payload.value
    expect_eq(removed_value, 15)

    expect(not values.contains(first_key))
    expect(values.len() == 1z, "len == 1 after remove")
    expect(values.remove(first_key).is_none())

    values.clear()
    expect(values.is_empty())
    expect(values.capacity() >= 4z, "capacity retained")


@[test]
function test_map_growth_and_collisions() -> void:
    var values = map.Map[CollisionKey, int].create()
    defer: values.release()

    var index: int = 0
    while index < 12:
        expect(values.set(CollisionKey(value = index), index * 10).is_none())
        index += 1

    expect(values.len() == 12z, "len == 12")
    expect(values.capacity() >= 12z, "capacity >= 12")

    index = 0
    while index < 12:
        expect_eq(read_int(values.get(CollisionKey(value = index))), index * 10)
        index += 1

    var removed_value = -1
    match values.remove(CollisionKey(value = 5)):
        Option.none:
            expect(false, "remove(5) none")
        Option.some as payload:
            removed_value = payload.value
    expect_eq(removed_value, 50)

    expect(values.get(CollisionKey(value = 5)) == null, "removed get null")
    expect_eq(read_int(values.get(CollisionKey(value = 4))), 40)
    expect_eq(read_int(values.get(CollisionKey(value = 6))), 60)


@[test]
function test_map_iterators_and_get_or_insert() -> void:
    var values = map.Map[Key, int].create()
    defer: values.release()

    let inserted = values.get_or_insert(Key(value = 3), 30)
    var inserted_value = 0
    unsafe:
        inserted_value = read(inserted)
        read(inserted) = 31
    expect_eq(inserted_value, 30)

    let existing = values.get_or_insert(Key(value = 3), 99)
    var existing_value = 0
    unsafe:
        existing_value = read(existing)
    expect_eq(existing_value, 31)

    var removed_key = 0
    var removed_value = 0
    match values.remove_entry(Key(value = 3)):
        Option.none:
            expect(false, "remove_entry none")
        Option.some as payload:
            removed_key = payload.value.key.value
            removed_value = payload.value.value
    expect_eq(removed_key, 3)
    expect_eq(removed_value, 31)

    expect(not values.contains(Key(value = 3)))

    values.set(Key(value = 1), 10)
    values.set(Key(value = 2), 20)

    let stored_key = values.get_key(Key(value = 2))
    expect(stored_key != null, "get_key non-null")
    var stored_key_value = 0
    unsafe:
        stored_key_value = read(ptr[Key]<-stored_key).value
    expect_eq(stored_key_value, 2)

    var key_total = 0
    for key in values.keys():
        unsafe:
            key_total += read(ptr[Key]<-key).value
    expect_eq(key_total, 3)

    var value_total = 0
    for value in values.values():
        unsafe:
            value_total += read(value)
    expect_eq(value_total, 30)

    var entry_total = 0
    for entry in values:
        unsafe:
            entry_total += read(ptr[Key]<-entry.key).value
            entry_total += read(entry.value)
    expect_eq(entry_total, 33)

    var current_total = 0
    var entries = values.entries()
    while entries.next():
        let entry = entries.current()
        unsafe:
            current_total += read(ptr[Key]<-entry.key).value
            if read(entry.value) == 20:
                read(entry.value) = 21
            current_total += read(entry.value)
    expect_eq(current_total, 34)

    for value in values.values():
        unsafe:
            if read(value) == 10:
                read(value) = 11

    expect_eq(read_int(values.get(Key(value = 1))), 11)
    expect_eq(read_int(values.get(Key(value = 2))), 21)
