# In-language tests for std.mem.pool (migrated from
# test/std/std_mem_pool_test.rb, run by `mtc test`).

import std.mem.pool as pool

struct Pair:
    left: int
    right: int

@[align(16)]
struct Mat4:
    data: array[float, 16]


@[test]
function test_pool_stable_storage_flow() -> void:
    var objects = pool.create(8, 2)
    defer: objects.release()

    expect(objects.remaining_slots() == 2, "2 slots remaining")

    let first = objects.alloc_bytes()
    let second = objects.alloc_bytes()
    let third = objects.alloc_bytes()
    expect(first != null and second != null, "first/second non-null")
    expect(third == null, "third over capacity is null")
    expect(objects.remaining_slots() == 0, "0 slots remaining")

    expect(objects.release_bytes(first))
    expect(objects.remaining_slots() == 1, "1 slot after release")

    let reused = objects.alloc_bytes()
    expect(reused != null, "reused non-null")
    expect(reused == first, "reused slot equals first")

    expect(objects.release_bytes(reused))
    expect(not objects.release_bytes(reused))
    expect(objects.release_bytes(second))
    expect(objects.remaining_slots() == 2, "2 slots after all released")


@[test]
function test_pool_typed_helpers() -> void:
    var objects = pool.create_for[Pair](2)
    defer: objects.release()

    let first = objects.alloc[Pair]()
    let second = objects.alloc[Pair]()
    let third = objects.alloc[Pair]()
    expect(first != null and second != null, "first/second non-null")
    expect(third == null, "third over capacity is null")

    var sum = 0
    unsafe:
        let base = ptr[Pair]<-first
        base.left = 8
        base.right = 13
        sum = base.left + base.right
    expect_eq(sum, 21)

    expect(objects.release_slot(first))
    expect(not objects.release_slot(first))
    expect(objects.release_slot(second))


@[test]
function test_pool_alignment_contracts() -> void:
    var raw = pool.create(6, 2)
    defer: raw.release()

    expect(raw.alloc[int]() == null, "int alloc in 6-byte slot is null")

    let small = raw.alloc[short]()
    expect(small != null, "short alloc non-null")

    var aligned = pool.create_for[Mat4](1)
    defer: aligned.release()

    let matrix = aligned.alloc[Mat4]()
    expect(matrix != null, "Mat4 alloc non-null")


@[test]
function test_pool_empty_without_backing_storage() -> void:
    var empty = pool.create(8, 0)
    defer: empty.release()

    expect(empty.remaining_slots() == 0, "no slots")
    expect(empty.alloc_bytes() == null, "alloc on empty pool is null")


@[test] @[expect_fatal]
function test_pool_zero_sized_non_empty_aborts() -> void:
    let _ = pool.create(0, 2)
