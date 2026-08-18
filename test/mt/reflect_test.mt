# In-language tests for reflective per-field hash/equal/order dispatch via
# `field.type` in type position (std.hash.equal_struct/hash_struct/order_struct).
# These exercise the compiler's resolution of `field.type` as a type in both the
# semantic and lowering phases, across heterogeneous field types (int + str).

import std.hash as hash
import std.fmt as fmt
import std.string as string

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
function test_equal_struct_content() -> void:
    let p1 = Pair(id = 1, name = "milk")
    let p2 = Pair(id = 1, name = "milk")
    let p3 = Pair(id = 1, name = "tea")
    expect(equal[Pair](p1, p2))
    expect(not equal[Pair](p1, p3))


@[test]
function test_hash_struct_consistent() -> void:
    let p1 = Pair(id = 2, name = "milk")
    let p2 = Pair(id = 2, name = "milk")
    expect(hash[Pair](p1) == hash[Pair](p2))


@[test]
function test_order_struct_lexicographic() -> void:
    let p1 = Pair(id = 1, name = "milk")
    let p2 = Pair(id = 1, name = "tea")
    expect(order[Pair](p1, p2) < 0)
    expect(order[Pair](p1, p1) == 0)


struct Wrapper:
    tag: int
    pair: Pair


extending Wrapper:
    static function hash(value: const_ptr[Wrapper]) -> uint:
        return hash.hash_struct[Wrapper](value)

    static function equal(a: const_ptr[Wrapper], b: const_ptr[Wrapper]) -> bool:
        return hash.equal_struct[Wrapper](a, b)

    static function order(a: const_ptr[Wrapper], b: const_ptr[Wrapper]) -> int:
        return hash.order_struct[Wrapper](a, b)


@[test]
function test_nested_equal_struct() -> void:
    let w1 = Wrapper(tag = 1, pair = Pair(id = 1, name = "milk"))
    let w2 = Wrapper(tag = 1, pair = Pair(id = 1, name = "milk"))
    let w3 = Wrapper(tag = 1, pair = Pair(id = 1, name = "tea"))
    expect(equal[Wrapper](w1, w2))
    expect(not equal[Wrapper](w1, w3))
    expect(order[Wrapper](w1, w3) < 0)


@[test]
function test_format_value_flat() -> void:
    var s = string.String.create()
    let p = Pair(id = 7, name = "milk")
    fmt.format_value[Pair](ref_of(s), const_ptr_of(p))
    expect_eq(s.as_str(), "{ id = 7, name = milk }")
    s.release()


@[test]
function test_format_value_nested() -> void:
    var s = string.String.create()
    let w = Wrapper(tag = 2, pair = Pair(id = 3, name = "tea"))
    fmt.format_value[Wrapper](ref_of(s), const_ptr_of(w))
    expect_eq(s.as_str(), "{ tag = 2, pair = { id = 3, name = tea } }")
    s.release()
