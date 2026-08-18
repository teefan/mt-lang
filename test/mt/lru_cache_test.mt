# In-language tests for std.lru_cache

import std.lru_cache as lru
import std.str


@[test]
function test_lru_cache_basic_set_and_get() -> void:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    expect(c.is_empty())
    expect(c.len() == 0z, "len == 0")
    expect(c.capacity() == 3z, "capacity == 3")

    c.set("a", 1)
    c.set("b", 2)
    expect(c.len() == 2z, "len == 2")
    expect(c.contains("a"))

    match c.at("b"):
        Option.some as payload:
            expect_eq(payload.value, 2)
        Option.none:
            expect(false, "at b returned none")


@[test]
function test_lru_cache_evicts_when_at_capacity() -> void:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.set("c", 3)
    expect(c.len() == 2z, "len == 2")
    expect(not c.contains("a"))
    expect(c.contains("b"))
    expect(c.contains("c"))


@[test]
function test_lru_cache_get_promotes_to_most_recent() -> void:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.get("a")
    c.set("c", 3)

    expect(c.contains("a"))
    expect(not c.contains("b"))


@[test]
function test_lru_cache_set_overwrites_and_promotes() -> void:
    var c = lru.LruCache[str, int].with_capacity(2)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.set("a", 10)
    c.set("c", 3)

    expect(c.contains("a"))
    expect(not c.contains("b"))
    match c.at("a"):
        Option.some as payload:
            expect_eq(payload.value, 10)
        Option.none:
            expect(false, "at a returned none")


@[test]
function test_lru_cache_remove_and_contains() -> void:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    c.set("x", 42)
    expect(c.contains("x"))
    expect(not c.contains("y"))

    expect(c.remove("x"))
    expect(not c.contains("x"))
    expect(not c.remove("x"))


@[test]
function test_lru_cache_clear() -> void:
    var c = lru.LruCache[str, int].with_capacity(3)
    defer: c.release()

    c.set("a", 1)
    c.set("b", 2)
    c.clear()

    expect(c.is_empty())
    expect(c.len() == 0z, "len == 0")
