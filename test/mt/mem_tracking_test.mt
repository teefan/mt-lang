import std.testing as t
import std.mem.tracking as tracking
import std.mem.heap as heap


@[test]
function test_tracker_create_empty() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    t.expect_equal_int(int<-(tracker.count()), 0)?
    t.expect_true(tracker.is_empty())?
    t.expect_equal_int(int<-(tracker.total_bytes()), 0)?
    return t.ok()


@[test]
function test_tracker_allock_free_no_leak() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    let p = tracking.alloc_bytes(ref_of(tracker), 16, "test_alloc") else:
        return t.fail("alloc failed")
    tracking.release_bytes(ref_of(tracker), p)
    t.expect_equal_int(int<-(tracker.count()), 0)?
    t.expect_true(tracker.is_empty())?
    return t.ok()


@[test]
function test_tracker_leak_detected() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    let p = tracking.alloc_bytes(ref_of(tracker), 32, "leak_test") else:
        return t.fail("alloc failed")
    t.expect_equal_int(int<-(tracker.count()), 1)?
    t.expect_true(not tracker.is_empty())?
    t.expect_equal_int(int<-(tracker.total_bytes()), 32)?
    tracking.release_bytes(ref_of(tracker), p)
    return t.ok()


@[test]
function test_tracker_multiple_allock() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    let a = tracking.alloc_bytes(ref_of(tracker), 8, "a") else:
        return t.fail("alloc a failed")
    let b = tracking.alloc_bytes(ref_of(tracker), 16, "b") else:
        return t.fail("alloc b failed")
    let c = tracking.alloc_bytes(ref_of(tracker), 32, "c") else:
        return t.fail("alloc c failed")
    t.expect_equal_int(int<-(tracker.count()), 3)?
    t.expect_equal_int(int<-(tracker.total_bytes()), 56)?
    tracking.release_bytes(ref_of(tracker), b)
    t.expect_equal_int(int<-(tracker.count()), 2)?
    tracking.release_bytes(ref_of(tracker), a)
    t.expect_equal_int(int<-(tracker.count()), 1)?
    tracking.release_bytes(ref_of(tracker), c)
    t.expect_equal_int(int<-(tracker.count()), 0)?
    return t.ok()


@[test]
function test_tracker_typed_allock() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    let p = tracking.alloc[int](ref_of(tracker), 4, "ints") else:
        return t.fail("typed alloc failed")
    t.expect_equal_int(int<-(tracker.count()), 1)?
    tracking.release(ref_of(tracker), p)
    t.expect_equal_int(int<-(tracker.count()), 0)?
    return t.ok()


@[test]
function test_tracker_must_allock() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    let p = tracking.must_alloc[ubyte](ref_of(tracker), 8, "must")
    t.expect_equal_int(int<-(tracker.count()), 1)?
    t.expect_equal_int(int<-(tracker.total_bytes()), 8)?
    tracking.release(ref_of(tracker), p)
    return t.ok()


@[test] @[expect_fatal]
function test_tracker_double_free_fatals() -> t.Check:
    var tracker = tracking.create()
    let p = tracking.must_alloc_bytes(ref_of(tracker), 8, "double")
    tracking.release_bytes(ref_of(tracker), p)
    tracking.release_bytes(ref_of(tracker), p)
    tracker.release()
    return t.ok()


@[test] @[expect_fatal]
function test_tracker_bad_free_fatals() -> t.Check:
    var tracker = tracking.create()
    let p = heap.alloc_bytes(8) else:
        fatal(c"alloc failed")
    tracking.release_bytes(ref_of(tracker), p)
    tracker.release()
    heap.release_bytes(p)
    return t.ok()


@[test]
function test_tracker_null_release_noop() -> t.Check:
    var tracker = tracking.create()
    defer tracker.release()
    tracking.release_bytes(ref_of(tracker), null)
    t.expect_equal_int(int<-(tracker.count()), 0)?
    return t.ok()
