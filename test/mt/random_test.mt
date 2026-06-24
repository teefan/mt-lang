# In-language tests for std.random (migrated from
# test/std/std_random_test.rb, run by `mtc test`).

import std.testing as t
import std.random as rng
import std.vec as vec

@[test]
function test_random_deterministic_output_from_seed() -> t.Check:
    var a = rng.from_seed(42)
    var b = rng.from_seed(42)
    var i: ptr_uint = 0
    while i < 10z:
        t.expect(a.next_u32() == b.next_u32(), "same seed same output")?
        i += 1
    return t.ok()


@[test]
function test_random_different_seeds_differ() -> t.Check:
    var a = rng.from_seed(1)
    var b = rng.from_seed(999)
    var diff = false
    var i: ptr_uint = 0
    while i < 10z:
        if a.next_u32() != b.next_u32():
            diff = true
            break
        i += 1
    return t.expect_true(diff)


@[test]
function test_random_fork_independent_streams() -> t.Check:
    var parent = rng.from_seed(12345)
    var child = parent.fork()
    var all_different = true
    var i: ptr_uint = 0
    while i < 10z:
        if parent.next_u32() == child.next_u32():
            all_different = false
            break
        i += 1
    return t.expect_true(all_different)


@[test]
function test_random_next_f64_in_range() -> t.Check:
    var r = rng.from_seed(7)
    var ok_range = true
    var i: ptr_uint = 0
    while i < 100z:
        let val = r.next_f64()
        if val < 0.0 or val >= 1.0:
            ok_range = false
            break
        i += 1
    return t.expect_true(ok_range)


@[test]
function test_random_next_bool_produces_both() -> t.Check:
    var r = rng.from_seed(100)
    var found_true = false
    var found_false = false
    var i: ptr_uint = 0
    while i < 50z:
        if r.next_bool():
            found_true = true
        else:
            found_false = true
        i += 1
    return t.expect(found_true and found_false, "both bool values produced")


@[test]
function test_random_next_uint_range_in_bounds() -> t.Check:
    var r = rng.from_seed(99)
    var ok_range = true
    var i: ptr_uint = 0
    while i < 200z:
        let val = r.next_uint_range(10, 20)
        if val < 10 or val >= 20:
            ok_range = false
            break
        i += 1
    return t.expect_true(ok_range)


@[test]
function test_random_next_int_range_in_bounds() -> t.Check:
    var r = rng.from_seed(77)
    var ok_range = true
    var i: ptr_uint = 0
    while i < 200z:
        let val = r.next_int_range(-5, 5)
        if val < -5 or val >= 5:
            ok_range = false
            break
        i += 1
    return t.expect_true(ok_range)


@[test]
function test_random_from_seed_str_deterministic() -> t.Check:
    var a = rng.from_seed_str("hello")
    var b = rng.from_seed_str("hello")
    var i: ptr_uint = 0
    while i < 5z:
        t.expect(a.next_u32() == b.next_u32(), "same string seed same output")?
        i += 1
    return t.ok()


@[test]
function test_random_shuffle_preserves_elements() -> t.Check:
    var r = rng.from_seed(55)
    var list = vec.Vec[uint].create()
    defer list.release()
    var k: uint = 0
    while k < 10:
        list.push(k)
        k += 1

    r.shuffle(ref_of(list))

    var counts = zero[array[uint, 10]]
    var in_range = true
    var i: ptr_uint = 0
    while i < list.len():
        let entity_ptr = list.get(i) else:
            return t.fail("list.get none")
        var val: uint = 0
        unsafe:
            val = read(entity_ptr)
        if val >= 10:
            in_range = false
            break
        counts[val] += 1
        i += 1
    t.expect_true(in_range)?

    var all_once = true
    var j: ptr_uint = 0
    while j < 10z:
        if counts[j] != 1:
            all_once = false
            break
        j += 1
    return t.expect_true(all_once)


@[test]
function test_random_skip_changes_output() -> t.Check:
    var a = rng.from_seed(42)
    a.skip(3)
    var b = rng.from_seed(42)
    var i: ptr_uint = 0
    while i < 3z:
        b.next_u32()
        i += 1
    return t.expect(a.next_u32() == b.next_u32(), "skip(3) matches three draws")


@[test]
function test_random_chance_always_true_with_one() -> t.Check:
    var r = rng.from_seed(42)
    var i: ptr_uint = 0
    while i < 10z:
        t.expect_true(r.chance(1.0))?
        i += 1
    return t.ok()


@[test]
function test_random_pick_returns_element() -> t.Check:
    var r = rng.from_seed(99)
    var list = vec.Vec[uint].create()
    defer list.release()
    var k: uint = 0
    while k < 5:
        list.push(k + 10)
        k += 1

    var picked: uint = 0
    match r.pick(ref_of(list)):
        Option.none:
            return t.fail("pick returned none")
        Option.some as sp:
            picked = sp.value
    return t.expect(picked >= 10 and picked <= 14, "picked in [10, 14]")
