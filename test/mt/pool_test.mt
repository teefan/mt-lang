## Object pool tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.pool as pool


struct TestItem:
    value: int
    active: bool


@[test]
function test_pool_acquire_all() -> t.Check:
    var p = pool.Pool[TestItem].create(4)
    defer: p.release()

    let a0 = p.acquire() else:
        return t.fail("expected acquire 0")
    let a1 = p.acquire() else:
        return t.fail("expected acquire 1")
    let a2 = p.acquire() else:
        return t.fail("expected acquire 2")
    let a3 = p.acquire() else:
        return t.fail("expected acquire 3")

    t.expect(int<-(a0) == 0, "first acquire is 0")?
    t.expect(int<-(a1) == 1, "second acquire is 1")?
    t.expect(int<-(a2) == 2, "third acquire is 2")?
    t.expect(int<-(a3) == 3, "fourth acquire is 3")?

    t.expect(p.available() == 0, "pool exhausted")?
    t.expect(p.count() == 4, "4 in use")?

    return t.ok()


@[test]
function test_pool_exhausted() -> t.Check:
    var p = pool.Pool[TestItem].create(2)
    defer: p.release()

    let _a = p.acquire()
    let _b = p.acquire()
    let c = p.acquire()

    match c:
        Option.none:
            return t.ok()
        Option.some:
            return t.fail("expected none on exhausted pool")

    return t.ok()


@[test]
function test_pool_release_and_reacquire() -> t.Check:
    var p = pool.Pool[TestItem].create(3)
    defer: p.release()

    let _a = p.acquire()
    let b = p.acquire() else:
        return t.fail("expected acquire")
    let _c = p.acquire()

    p.release_object(b)

    let d = p.acquire() else:
        return t.fail("expected re-acquire")
    t.expect(d == b, "re-acquire same index")?

    return t.ok()


@[test]
function test_pool_get_set() -> t.Check:
    var p = pool.Pool[TestItem].create(4)
    defer: p.release()

    let id = p.acquire() else:
        return t.fail("expected acquire")
    let item_ptr = p.get(id)
    if item_ptr == null:
        return t.fail("get returned null")

    unsafe:
        read(item_ptr).value = 42
    unsafe:
        t.expect(read(item_ptr).value == 42, "value set through ptr")?

    return t.ok()


@[test]
function test_pool_get_oob() -> t.Check:
    var p = pool.Pool[TestItem].create(2)
    defer: p.release()

    let item = p.get(99)
    t.expect(item == null, "out-of-bounds returns null")?

    return t.ok()


@[test]
function test_pool_clear() -> t.Check:
    var p = pool.Pool[TestItem].create(3)
    defer: p.release()

    let _a = p.acquire()
    let _b = p.acquire()
    t.expect(p.available() == 1, "one left after 2 acquires")?

    p.clear()
    t.expect(p.available() == 3, "all available after clear")?

    return t.ok()


@[test]
function test_pool_count() -> t.Check:
    var p = pool.Pool[TestItem].create(5)
    defer: p.release()

    t.expect(p.count() == 0, "count starts at 0")?
    let _a = p.acquire()
    t.expect(p.count() == 1, "count after acquire")?
    let _b = p.acquire()
    t.expect(p.count() == 2, "count after 2 acquires")?

    return t.ok()
