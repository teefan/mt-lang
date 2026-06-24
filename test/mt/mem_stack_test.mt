# In-language tests for std.mem.stack (migrated from
# test/std/std_mem_stack_test.rb, run by `mtc test`).

import std.testing as t
import std.mem.stack as stack

struct Pair:
    left: int
    right: int

@[align(16)]
struct Mat4:
    data: array[float, 16]


@[test]
function test_mem_stack_temporary_flow() -> t.Check:
    var temp = stack.create(24)
    defer temp.release()

    let start = temp.mark()
    let first = temp.alloc_bytes(8)
    let nested = temp.mark()
    let second = temp.alloc_bytes(8)
    t.expect(first != null and second != null, "allocs non-null")?

    temp.reset(nested)
    t.expect(temp.remaining_bytes() == 16, "remaining == 16 after nested reset")?

    temp.reset(start)
    t.expect(temp.remaining_bytes() == 24, "remaining == 24 after full reset")?

    let too_big = temp.alloc_bytes(32)
    return t.expect(too_big == null, "oversized alloc is null")


@[test]
function test_mem_stack_typed_allocation() -> t.Check:
    var temp = stack.create_for[Pair](1)
    defer temp.release()

    let pair = temp.alloc[Pair](1)
    t.expect(pair != null, "pair alloc non-null")?

    var sum = 0
    unsafe:
        let base = ptr[Pair]<-pair
        base.left = 2
        base.right = 4
        sum = base.left + base.right
    t.expect_equal_int(sum, 6)?

    let exhausted = temp.alloc[Pair](1)
    return t.expect(exhausted == null, "exhausted alloc is null")


@[test]
function test_mem_stack_aligned_allocation() -> t.Check:
    var temp = stack.create_for[Mat4](1)
    defer temp.release()

    let matrix = temp.alloc[Mat4](1)
    t.expect(matrix != null, "matrix alloc non-null")?

    let exhausted = temp.alloc[Mat4](1)
    return t.expect(exhausted == null, "exhausted alloc is null")
