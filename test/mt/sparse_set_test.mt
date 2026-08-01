# In-language tests for std.sparse_set

import std.testing as t
import std.sparse_set as sset


@[test]
function test_sparse_set_insert_and_get() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    t.expect_true(s.is_empty())?
    t.expect(s.len() == 0z, "len == 0")?

    t.expect_true(s.insert(100, 42))?
    t.expect_false(s.insert(100, 99))?
    t.expect(s.len() == 1z, "len == 1")?

    t.expect_true(s.contains(100))?
    t.expect_false(s.contains(0))?

    match s.at(100):
        Option.some as payload:
            t.expect_equal_int(payload.value, 42)?
        Option.none:
            return t.fail("at(100) returned none")

    return t.expect_equal_int(int<-(s.len()), 1)


@[test]
function test_sparse_set_remove_swaps_last() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(10, 1)
    s.insert(20, 2)
    s.insert(30, 3)

    t.expect_true(s.contains(10))?
    t.expect_true(s.remove(10))?
    t.expect_false(s.contains(10))?
    t.expect(s.len() == 2z, "len == 2")?

    t.expect_true(s.contains(20))?
    t.expect_true(s.contains(30))?
    match s.at(20):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 2)
        Option.none:
            return t.fail("at(20) returned none after removal")


@[test]
function test_sparse_set_remove_nonexistent_returns_false() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(5, 99)
    t.expect_false(s.remove(999))?
    return t.expect(s.len() == 1z, "len unchanged")


@[test]
function test_sparse_set_key_outside_range() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    t.expect_false(s.contains(0))?
    t.expect(s.get(0) == null, "get(0) null")?
    return t.expect_none[int](s.at(0))


@[test]
function test_sparse_set_clear_and_reinsert() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(1, 10)
    s.insert(2, 20)
    t.expect(s.len() == 2z, "len == 2")?

    s.clear()
    t.expect_true(s.is_empty())?
    t.expect(s.len() == 0z, "len == 0")?

    return t.expect_true(s.insert(1, 30))


@[test]
function test_sparse_set_shrink_to_fit() -> t.Check:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(10, 1)
    s.insert(20, 2)
    s.reserve(128)
    t.expect(s.len() == 2z, "len == 2")?

    s.shrink_to_fit()
    t.expect_true(s.contains(10))?
    t.expect_true(s.contains(20))?
    match s.at(10):
        Option.some as payload:
            t.expect_equal_int(payload.value, 1)?
        Option.none:
            return t.fail("at(10) returned none after shrink")
    match s.at(20):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 2)
        Option.none:
            return t.fail("at(20) returned none after shrink")
