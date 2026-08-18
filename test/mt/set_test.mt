# In-language tests for std.set (migrated from
# test/std/std_set_test.rb, run by `mtc test`).

import std.set as set

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


@[test]
function test_set_basic_operations() -> void:
    var values = set.Set[Key].with_capacity(4)
    defer: values.release()

    expect(values.capacity() >= 4z, "capacity >= 4")
    expect(values.is_empty())
    expect(not values.contains(Key(value = 1)))

    expect(values.insert(Key(value = 1)))
    expect(not values.insert(Key(value = 1)))
    expect(values.insert(Key(value = 2)))

    expect(values.len() == 2z, "len == 2")
    expect(values.contains(Key(value = 2)))

    let stored = values.get(Key(value = 2))
    expect(stored != null, "get(2) non-null")
    var stored_value = 0
    unsafe:
        stored_value = read(ptr[Key]<-stored).value
    expect_eq(stored_value, 2)

    expect(not values.remove(Key(value = 3)))
    expect(values.remove(Key(value = 1)))
    expect(not values.contains(Key(value = 1)))
    expect(values.len() == 1z, "len == 1")

    values.clear()
    expect(values.is_empty())
    expect(values.capacity() >= 4z, "capacity retained")


@[test]
function test_set_growth_and_iteration() -> void:
    var values = set.Set[CollisionKey].create()
    defer: values.release()

    var index: int = 0
    while index < 12:
        expect(values.insert(CollisionKey(value = index)))
        index += 1

    expect(values.len() == 12z, "len == 12")
    expect(values.capacity() >= 12z, "capacity >= 12")

    var total = 0
    var count = 0
    for value in values:
        unsafe:
            total += read(ptr[CollisionKey]<-value).value
        count += 1
    expect_eq(count, 12)
    expect_eq(total, 66)

    var iter = values.iter()
    var manual_total = 0
    var manual_count = 0
    while true:
        let value = iter.next()
        if value == null:
            break
        unsafe:
            manual_total += read(ptr[CollisionKey]<-value).value
        manual_count += 1
    expect_eq(manual_count, 12)
    expect_eq(manual_total, 66)

    expect(values.remove(CollisionKey(value = 5)))
    expect(not values.contains(CollisionKey(value = 5)))
    expect(values.len() == 11z, "len == 11")


@[test]
function test_set_algebra_operations() -> void:
    var left = set.Set[Key].create()
    defer: left.release()
    var right = set.Set[Key].create()
    defer: right.release()
    var subset = set.Set[Key].create()
    defer: subset.release()

    left.insert(Key(value = 1))
    left.insert(Key(value = 2))
    left.insert(Key(value = 3))
    right.insert(Key(value = 3))
    right.insert(Key(value = 4))
    subset.insert(Key(value = 1))
    subset.insert(Key(value = 3))

    expect(subset.is_subset(left))
    expect(not right.is_subset(left))

    var union_values = left.union_with(right)
    defer: union_values.release()
    expect(union_values.len() == 4z, "union len == 4")
    expect(union_values.contains(Key(value = 1)))
    expect(union_values.contains(Key(value = 4)))

    var intersection_values = left.intersection(right)
    defer: intersection_values.release()
    expect(intersection_values.len() == 1z, "intersection len == 1")
    expect(intersection_values.contains(Key(value = 3)))
    expect(intersection_values.is_subset(left))

    var difference_values = left.difference(right)
    defer: difference_values.release()
    expect(difference_values.len() == 2z, "difference len == 2")
    expect(difference_values.contains(Key(value = 1)))
    expect(not difference_values.contains(Key(value = 3)))

    expect(left.len() == 3z, "left len == 3")
    expect(right.len() == 2z, "right len == 2")
