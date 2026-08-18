import std.mem.tracking as tracking
import std.mem.heap as heap


@[test]
function test_tracker_create_empty() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    expect_eq(int<-(tracker.count()), 0)
    expect(tracker.is_empty())
    expect_eq(int<-(tracker.total_bytes()), 0)


@[test]
function test_tracker_allock_free_no_leak() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    let p = tracking.alloc_bytes(ref_of(tracker), 16, "test_alloc") else:
        expect(false, "alloc failed")
        return
    tracking.release_bytes(ref_of(tracker), p)
    expect_eq(int<-(tracker.count()), 0)
    expect(tracker.is_empty())


@[test]
function test_tracker_leak_detected() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    let p = tracking.alloc_bytes(ref_of(tracker), 32, "leak_test") else:
        expect(false, "alloc failed")
        return
    expect_eq(int<-(tracker.count()), 1)
    expect(not tracker.is_empty())
    expect_eq(int<-(tracker.total_bytes()), 32)
    tracking.release_bytes(ref_of(tracker), p)


@[test]
function test_tracker_multiple_allock() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    let a = tracking.alloc_bytes(ref_of(tracker), 8, "a") else:
        expect(false, "alloc a failed")
        return
    let b = tracking.alloc_bytes(ref_of(tracker), 16, "b") else:
        expect(false, "alloc b failed")
        return
    let c = tracking.alloc_bytes(ref_of(tracker), 32, "c") else:
        expect(false, "alloc c failed")
        return
    expect_eq(int<-(tracker.count()), 3)
    expect_eq(int<-(tracker.total_bytes()), 56)
    tracking.release_bytes(ref_of(tracker), b)
    expect_eq(int<-(tracker.count()), 2)
    tracking.release_bytes(ref_of(tracker), a)
    expect_eq(int<-(tracker.count()), 1)
    tracking.release_bytes(ref_of(tracker), c)
    expect_eq(int<-(tracker.count()), 0)


@[test]
function test_tracker_typed_allock() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    let p = tracking.alloc[int](ref_of(tracker), 4, "ints") else:
        expect(false, "typed alloc failed")
        return
    expect_eq(int<-(tracker.count()), 1)
    tracking.release(ref_of(tracker), p)
    expect_eq(int<-(tracker.count()), 0)


@[test]
function test_tracker_must_allock() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    let p = tracking.must_alloc[ubyte](ref_of(tracker), 8, "must")
    expect_eq(int<-(tracker.count()), 1)
    expect_eq(int<-(tracker.total_bytes()), 8)
    tracking.release(ref_of(tracker), p)


@[test] @[expect_fatal]
function test_tracker_double_free_fatals() -> void:
    var tracker = tracking.create()
    let p = tracking.must_alloc_bytes(ref_of(tracker), 8, "double")
    tracking.release_bytes(ref_of(tracker), p)
    tracking.release_bytes(ref_of(tracker), p)
    tracker.release()


@[test] @[expect_fatal]
function test_tracker_bad_free_fatals() -> void:
    var tracker = tracking.create()
    let p = heap.alloc_bytes(8) else:
        fatal(c"alloc failed")
    tracking.release_bytes(ref_of(tracker), p)
    tracker.release()
    heap.release_bytes(p)


@[test]
function test_tracker_null_release_noop() -> void:
    var tracker = tracking.create()
    defer: tracker.release()
    tracking.release_bytes(ref_of(tracker), null)
    expect_eq(int<-(tracker.count()), 0)
