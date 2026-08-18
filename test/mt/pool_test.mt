## Object pool tests.
## Run via `mtc test test/mt/`.

import std.pool as pool


struct TestItem:
    value: int
    active: bool


@[test]
function test_pool_acquire_all() -> void:
    var p = pool.Pool[TestItem].create(4)
    defer: p.release()

    let a0 = p.acquire() else:
        expect(false, "expected acquire 0")
        return
    let a1 = p.acquire() else:
        expect(false, "expected acquire 1")
        return
    let a2 = p.acquire() else:
        expect(false, "expected acquire 2")
        return
    let a3 = p.acquire() else:
        expect(false, "expected acquire 3")
        return

    expect(int<-(a0) == 0, "first acquire is 0")
    expect(int<-(a1) == 1, "second acquire is 1")
    expect(int<-(a2) == 2, "third acquire is 2")
    expect(int<-(a3) == 3, "fourth acquire is 3")

    expect(p.available() == 0, "pool exhausted")
    expect(p.count() == 4, "4 in use")



@[test]
function test_pool_exhausted() -> void:
    var p = pool.Pool[TestItem].create(2)
    defer: p.release()

    let _a = p.acquire()
    let _b = p.acquire()
    let c = p.acquire()

    match c:
        Option.none:
        Option.some:
            expect(false, "expected none on exhausted pool")



@[test]
function test_pool_release_and_reacquire() -> void:
    var p = pool.Pool[TestItem].create(3)
    defer: p.release()

    let _a = p.acquire()
    let b = p.acquire() else:
        expect(false, "expected acquire")
        return
    let _c = p.acquire()

    p.release_object(b)

    let d = p.acquire() else:
        expect(false, "expected re-acquire")
        return
    expect(d == b, "re-acquire same index")



@[test]
function test_pool_get_set() -> void:
    var p = pool.Pool[TestItem].create(4)
    defer: p.release()

    let id = p.acquire() else:
        expect(false, "expected acquire")
        return
    let item_ptr = p.get(id)
    if item_ptr == null:
        expect(false, "get returned null")

    unsafe:
        read(item_ptr).value = 42
    unsafe:
        expect(read(item_ptr).value == 42, "value set through ptr")



@[test]
function test_pool_get_oob() -> void:
    var p = pool.Pool[TestItem].create(2)
    defer: p.release()

    let item = p.get(99)
    expect(item == null, "out-of-bounds returns null")



@[test]
function test_pool_clear() -> void:
    var p = pool.Pool[TestItem].create(3)
    defer: p.release()

    let _a = p.acquire()
    let _b = p.acquire()
    expect(p.available() == 1, "one left after 2 acquires")

    p.clear()
    expect(p.available() == 3, "all available after clear")



@[test]
function test_pool_count() -> void:
    var p = pool.Pool[TestItem].create(5)
    defer: p.release()

    expect(p.count() == 0, "count starts at 0")
    let _a = p.acquire()
    expect(p.count() == 1, "count after acquire")
    let _b = p.acquire()
    expect(p.count() == 2, "count after 2 acquires")

