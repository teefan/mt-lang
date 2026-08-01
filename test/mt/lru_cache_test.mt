# In-language tests for std.lru_cache

import std.testing as t
import std.lru_cache as lru
import std.str


@[test]
function test_lru_cache_basic_set_and_get() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    t.expect_true(c.is_empty())?
    t.expect(c.len() == 0z, "len == 0")?
    t.expect(c.capacity() == 3z, "capacity == 3")?

    c.set("a", 1)
    c.set("b", 2)
    t.expect(c.len() == 2z, "len == 2")?
    t.expect_true(c.contains("a"))?

    match c.at("b"):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 2)
        Option.none:
            return t.fail("at b returned none")


@[test]
function test_lru_cache_evicts_when_at_capacity() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.set("c", 3)
    t.expect(c.len() == 2z, "len == 2")?
    t.expect_false(c.contains("a"))?
    t.expect_true(c.contains("b"))?
    return t.expect_true(c.contains("c"))


@[test]
function test_lru_cache_get_promotes_to_most_recent() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.get("a")
    c.set("c", 3)

    t.expect_true(c.contains("a"))?
    return t.expect_false(c.contains("b"))


@[test]
function test_lru_cache_set_overwrites_and_promotes() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.set("a", 10)
    c.set("c", 3)

    t.expect_true(c.contains("a"))?
    t.expect_false(c.contains("b"))?
    match c.at("a"):
        Option.some as payload:
            return t.expect_equal_int(payload.value, 10)
        Option.none:
            return t.fail("at a returned none")


@[test]
function test_lru_cache_remove_and_contains() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    c.set("x", 42)
    t.expect_true(c.contains("x"))?
    t.expect_false(c.contains("y"))?

    t.expect_true(c.remove("x"))?
    t.expect_false(c.contains("x"))?
    return t.expect_false(c.remove("x"))


@[test]
function test_lru_cache_clear() -> t.Check:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.clear()

    t.expect_true(c.is_empty())?
    return t.expect(c.len() == 0z, "len == 0")
