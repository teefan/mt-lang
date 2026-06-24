# In-language tests for std.mem.arena (migrated from
# test/std/std_mem_arena_test.rb, run by `mtc test`).

import std.testing as t
import std.mem.arena as arena
import std.str as str

struct Pair:
    left: int
    right: int

@[align(16)]
struct Mat4:
    data: array[float, 16]


@[test]
function test_arena_lifetime_flow() -> t.Check:
    var scratch = arena.create(32)
    defer scratch.release()

    let start = scratch.mark()
    t.expect(start == 0, "initial mark == 0")?

    let first = scratch.alloc_bytes(8)
    let after_first = scratch.mark()
    let second = scratch.alloc_bytes(16)
    t.expect(first != null and second != null, "allocs non-null")?
    t.expect(after_first == 8, "mark after first == 8")?
    t.expect(scratch.remaining_bytes() == 8, "remaining == 8")?

    scratch.reset(after_first)
    t.expect(scratch.remaining_bytes() == 24, "remaining == 24 after partial reset")?

    scratch.reset(start)
    t.expect(scratch.remaining_bytes() == 32, "remaining == 32 after full reset")?

    let too_big = scratch.alloc_bytes(64)
    return t.expect(too_big == null, "oversized alloc is null")


@[test]
function test_arena_typed_allocation() -> t.Check:
    var scratch = arena.create_for[Pair](1)
    defer scratch.release()

    let pair = scratch.alloc[Pair](1)
    t.expect(pair != null, "pair alloc non-null")?

    var sum = 0
    unsafe:
        let base = ptr[Pair]<-pair
        base.left = 7
        base.right = 3
        sum = base.left + base.right
    t.expect_equal_int(sum, 10)?

    let exhausted = scratch.alloc[Pair](1)
    return t.expect(exhausted == null, "exhausted alloc is null")


@[test]
function test_arena_cstr_helpers() -> t.Check:
    var scratch = arena.create(16)
    defer scratch.release()

    let copied = scratch.try_to_cstr("milk")
    if copied == null:
        return t.fail("try_to_cstr returned null")
    t.expect_true(str.cstr_as_str(copied).equal("milk"))?

    let copied_again = scratch.to_cstr("tea")
    return t.expect_true(str.cstr_as_str(copied_again).equal("tea"))


@[test]
function test_arena_aligned_allocation() -> t.Check:
    var scratch = arena.create_for[Mat4](1)
    defer scratch.release()

    let matrix = scratch.alloc[Mat4](1)
    t.expect(matrix != null, "matrix alloc non-null")?

    let exhausted = scratch.alloc[Mat4](1)
    return t.expect(exhausted == null, "exhausted alloc is null")


@[test] @[expect_fatal]
function test_arena_invalid_mark_aborts() -> t.Check:
    var scratch = arena.create(32)
    defer scratch.release()

    let first = scratch.alloc_bytes(8)
    t.expect(first != null, "alloc non-null")?
    scratch.reset(16)
    return t.ok()
