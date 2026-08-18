# In-language tests for std.sparse_set

import std.sparse_set as sset


@[test]
function test_sparse_set_insert_and_get() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    expect(s.is_empty())
    expect(s.len() == 0z, "len == 0")

    expect(s.insert(100, 42))
    expect(not s.insert(100, 99))
    expect(s.len() == 1z, "len == 1")

    expect(s.contains(100))
    expect(not s.contains(0))

    match s.at(100):
        Option.some as payload:
            expect_eq(payload.value, 42)
        Option.none:
            expect(false, "at(100) returned none")

    expect_eq(int<-(s.len()), 1)


@[test]
function test_sparse_set_remove_swaps_last() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(10, 1)
    s.insert(20, 2)
    s.insert(30, 3)

    expect(s.contains(10))
    expect(s.remove(10))
    expect(not s.contains(10))
    expect(s.len() == 2z, "len == 2")

    expect(s.contains(20))
    expect(s.contains(30))
    match s.at(20):
        Option.some as payload:
            expect_eq(payload.value, 2)
        Option.none:
            expect(false, "at(20) returned none after removal")


@[test]
function test_sparse_set_remove_nonexistent_returns_false() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(5, 99)
    expect(not s.remove(999))
    expect(s.len() == 1z, "len unchanged")


@[test]
function test_sparse_set_key_outside_range() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    expect(not s.contains(0))
    expect(s.get(0) == null, "get(0) null")
    expect(s.at(0).is_none())


@[test]
function test_sparse_set_clear_and_reinsert() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(1, 10)
    s.insert(2, 20)
    expect(s.len() == 2z, "len == 2")

    s.clear()
    expect(s.is_empty())
    expect(s.len() == 0z, "len == 0")

    expect(s.insert(1, 30))


@[test]
function test_sparse_set_shrink_to_fit() -> void:
    var s = sset.SparseSet[int].create()
    defer: s.release()

    s.insert(10, 1)
    s.insert(20, 2)
    s.reserve(128)
    expect(s.len() == 2z, "len == 2")

    s.shrink_to_fit()
    expect(s.contains(10))
    expect(s.contains(20))
    match s.at(10):
        Option.some as payload:
            expect_eq(payload.value, 1)
        Option.none:
            expect(false, "at(10) returned none after shrink")
    match s.at(20):
        Option.some as payload:
            expect_eq(payload.value, 2)
        Option.none:
            expect(false, "at(20) returned none after shrink")
