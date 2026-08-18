# In-language tests for std.bitset

import std.bitset as bitset


@[test]
function test_bitset_set_and_test() -> void:
    var b = bitset.with_capacity(64)
    defer: b.release()

    expect(not b.test(0))
    expect(not b.test(42))

    b.set(0)
    b.set(42)
    expect(b.test(0))
    expect(b.test(42))
    expect(not b.test(1))

    expect_eq(int<-(b.count()), 2)


@[test]
function test_bitset_clear_and_toggle() -> void:
    var b = bitset.with_capacity(64)
    defer: b.release()

    b.set(10)
    expect(b.test(10))
    b.clear(10)
    expect(not b.test(10))

    b.toggle(3)
    expect(b.test(3))
    b.toggle(3)
    expect(not b.test(3))


@[test]
function test_bitset_all_and_none() -> void:
    var b = bitset.with_capacity(64)
    defer: b.release()

    expect(b.none())
    expect(not b.any())

    b.set(5)
    expect(not b.none())
    expect(b.any())


@[test]
function test_bitset_count_after_ops() -> void:
    var b = bitset.with_capacity(128)
    defer: b.release()

    expect_eq(int<-(b.count()), 0)
    expect(b.none())

    b.set(0)
    b.set(63)
    b.set(64)
    expect_eq(int<-(b.count()), 3)
    expect(not b.none())

    b.clear(0)
    expect_eq(int<-(b.count()), 2)


@[test]
function test_bitset_clear_all_resets_bits() -> void:
    var b = bitset.with_capacity(64)
    defer: b.release()

    b.set(1)
    b.set(2)
    b.set(3)
    expect_eq(int<-(b.count()), 3)

    b.clear_all()
    expect_eq(int<-(b.count()), 0)
    expect(not b.test(1))
    expect(b.none())


@[test]
function test_bitset_find_first() -> void:
    var b = bitset.with_capacity(128)
    defer: b.release()

    b.set(7)
    b.set(10)
    b.set(100)

    let found = b.find_first_set()
    match found:
        Option.some as payload:
            expect_eq(int<-(payload.value), 7)
        Option.none:
            expect(false, "expected first set at 7")
