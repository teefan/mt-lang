# In-language tests for std.bitset

import std.testing as t
import std.bitset as bitset


@[test]
function test_bitset_set_and_test() -> t.Check:
    var b = bitset.with_capacity(64)
    defer b.release()

    t.expect_false(b.test(0))?
    t.expect_false(b.test(42))?

    b.set(0)
    b.set(42)
    t.expect_true(b.test(0))?
    t.expect_true(b.test(42))?
    t.expect_false(b.test(1))?

    return t.expect_equal_int(int<-(b.count()), 2)


@[test]
function test_bitset_clear_and_toggle() -> t.Check:
    var b = bitset.with_capacity(64)
    defer b.release()

    b.set(10)
    t.expect_true(b.test(10))?
    b.clear(10)
    t.expect_false(b.test(10))?

    b.toggle(3)
    t.expect_true(b.test(3))?
    b.toggle(3)
    return t.expect_false(b.test(3))


@[test]
function test_bitset_all_and_none() -> t.Check:
    var b = bitset.with_capacity(64)
    defer b.release()

    t.expect_true(b.none())?
    t.expect_false(b.any())?

    b.set(5)
    t.expect_false(b.none())?
    return t.expect_true(b.any())


@[test]
function test_bitset_count_after_ops() -> t.Check:
    var b = bitset.with_capacity(128)
    defer b.release()

    t.expect_equal_int(int<-(b.count()), 0)?
    t.expect_true(b.none())?

    b.set(0)
    b.set(63)
    b.set(64)
    t.expect_equal_int(int<-(b.count()), 3)?
    t.expect_false(b.none())?

    b.clear(0)
    return t.expect_equal_int(int<-(b.count()), 2)


@[test]
function test_bitset_clear_all_resets_bits() -> t.Check:
    var b = bitset.with_capacity(64)
    defer b.release()

    b.set(1)
    b.set(2)
    b.set(3)
    t.expect_equal_int(int<-(b.count()), 3)?

    b.clear_all()
    t.expect_equal_int(int<-(b.count()), 0)?
    t.expect_false(b.test(1))?
    return t.expect_true(b.none())


@[test]
function test_bitset_find_first() -> t.Check:
    var b = bitset.with_capacity(128)
    defer b.release()

    b.set(7)
    b.set(10)
    b.set(100)

    let found = b.find_first_set()
    match found:
        Option.some as payload:
            return t.expect_equal_int(int<-(payload.value), 7)
        Option.none:
            return t.fail("expected first set at 7")
