# In-language tests for reflective per-field hash/equal/order dispatch via
# `field.type` in type position (std.hash.equal_struct/hash_struct/order_struct).
# These exercise the compiler's resolution of `field.type` as a type in both the
# semantic and lowering phases, across heterogeneous field types (int + str).

import std.testing as t
import std.hash as hash

struct Pair:
    id: int
    name: str


extending Pair:
    static function hash(value: const_ptr[Pair]) -> uint:
        return hash.hash_struct[Pair](value)

    static function equal(a: const_ptr[Pair], b: const_ptr[Pair]) -> bool:
        return hash.equal_struct[Pair](a, b)

    static function order(a: const_ptr[Pair], b: const_ptr[Pair]) -> int:
        return hash.order_struct[Pair](a, b)


@[test]
function test_equal_struct_content() -> t.Check:
    let p1 = Pair(id = 1, name = "milk")
    let p2 = Pair(id = 1, name = "milk")
    let p3 = Pair(id = 1, name = "tea")
    t.expect_true(equal[Pair](p1, p2))?
    t.expect_false(equal[Pair](p1, p3))?
    return t.ok()


@[test]
function test_hash_struct_consistent() -> t.Check:
    let p1 = Pair(id = 2, name = "milk")
    let p2 = Pair(id = 2, name = "milk")
    return t.expect_true(hash[Pair](p1) == hash[Pair](p2))


@[test]
function test_order_struct_lexicographic() -> t.Check:
    let p1 = Pair(id = 1, name = "milk")
    let p2 = Pair(id = 1, name = "tea")
    t.expect_true(order[Pair](p1, p2) < 0)?
    t.expect_true(order[Pair](p1, p1) == 0)?
    return t.ok()
