# In-language tests for std.net.sync (migrated from
# test/std/std_sync_test.rb, run by `mtc test`).

import std.testing as t
import std.net.sync as sync
import std.vec as vec

@[test]
function test_sync_value_dirty_tracking() -> t.Check:
    var hp = sync.SyncValue[float](value = 100.0, dirty = false)
    t.expect_false(hp.dirty)?
    hp.set(90.0)
    t.expect_true(hp.dirty)?
    t.expect(hp.get() == 90.0, "get == 90.0")?
    hp.mark_clean()
    t.expect_false(hp.dirty)?
    return t.expect(hp.get() == 90.0, "get == 90.0 after clean")


@[test]
function test_sync_value_with_uint() -> t.Check:
    var score = sync.SyncValue[uint](value = 0, dirty = false)
    t.expect_false(score.has_changed())?
    score.set(42)
    t.expect_true(score.has_changed())?
    t.expect(score.get() == 42, "get == 42")?
    score.mark_clean()
    t.expect_false(score.has_changed())?
    return t.expect(score.get() == 42, "get == 42 after clean")


@[test]
function test_sync_list_push_and_length() -> t.Check:
    var list = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)
    defer list.items.release()

    t.expect_false(list.dirty)?
    t.expect(list.len() == 0, "len == 0")?

    list.push(10)
    t.expect_true(list.dirty)?
    t.expect(list.len() == 1, "len == 1")?

    let entity_ptr = list.get(0) else:
        return t.fail("get(0) none")
    var first = 0
    unsafe:
        first = int<-read(entity_ptr)
    t.expect_equal_int(first, 10)?

    list.mark_clean()
    t.expect_false(list.dirty)?

    list.clear()
    t.expect_true(list.dirty)?
    return t.expect(list.len() == 0, "len == 0 after clear")


@[test]
function test_sync_list_multiple_items() -> t.Check:
    var events = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)
    defer events.items.release()

    events.push(100)
    events.push(200)
    events.push(300)

    t.expect(events.len() == 3, "len == 3")?
    t.expect_true(events.dirty)?

    let p0 = events.get(0) else:
        return t.fail("get(0) none")
    let p1 = events.get(1) else:
        return t.fail("get(1) none")
    let p2 = events.get(2) else:
        return t.fail("get(2) none")
    var v0 = 0
    var v1 = 0
    var v2 = 0
    unsafe:
        v0 = int<-read(p0)
        v1 = int<-read(p1)
        v2 = int<-read(p2)
    t.expect_equal_int(v0, 100)?
    t.expect_equal_int(v1, 200)?
    t.expect_equal_int(v2, 300)?

    events.mark_clean()
    return t.expect_false(events.dirty)


@[test]
function test_sync_lerp_interpolates() -> t.Check:
    var lerp = sync.Lerp(
        previous = 0.0,
        target = 100.0,
        elapsed = 0.0,
        duration = 1.0
    )

    t.expect(lerp.current() == 0.0, "current == 0 at t=0")?

    lerp.tick(0.5)
    let mid = lerp.current()
    t.expect(mid >= 49.0 and mid <= 51.0, "current ~50 at t=0.5")?

    lerp.tick(0.5)
    t.expect(lerp.current() == 100.0, "current == 100 at t=1")?
    t.expect_true(lerp.has_arrived())?

    lerp.set_target(200.0, 1.0)
    t.expect(lerp.current() == 100.0, "current == 100 after set_target")?

    lerp.tick(1.0)
    return t.expect(lerp.current() == 200.0, "current == 200 after tick")


@[test]
function test_sync_compressed_u16_roundtrip() -> t.Check:
    var c = sync.CompressedUshort(min = 0.0, max = 1000.0)

    let original: float = 500.0
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)
    t.expect(decoded >= 499.9 and decoded <= 500.1, "500 round-trips within precision")?

    var lo = c.decode(c.encode(0.0))
    t.expect(lo >= -0.1 and lo <= 0.1, "min round-trips")?

    var hi = c.decode(c.encode(1000.0))
    t.expect(hi >= 999.9 and hi <= 1000.1, "max round-trips")?

    var clamped = c.decode(c.encode(-500.0))
    return t.expect(clamped >= -0.1 and clamped <= 0.1, "below min clamps to min")


@[test]
function test_sync_compressed_u8_roundtrip() -> t.Check:
    var c = sync.CompressedUbyte(min = -1.0, max = 1.0)

    let original: float = 0.5
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)
    t.expect(decoded >= 0.48 and decoded <= 0.52, "0.5 round-trips within precision")?

    var zero_value = c.decode(c.encode(0.0))
    return t.expect(zero_value >= -0.02 and zero_value <= 0.02, "zero stays near zero")


@[test]
function test_sync_tick_buffer_push_and_get() -> t.Check:
    var buf = sync.TickBuffer[uint](
        entries = vec.Vec[uint].create(),
        base_tick = 0
    )
    defer buf.entries.release()

    buf.push(0, 100)
    buf.push(1, 200)
    buf.push(2, 300)

    var v0 = 0
    match buf.get(0):
        Option.some as r0:
            v0 = int<-r0.value
        Option.none:
            return t.fail("get(0) none")
    t.expect_equal_int(v0, 100)?

    var v1 = 0
    match buf.get(1):
        Option.some as r1:
            v1 = int<-r1.value
        Option.none:
            return t.fail("get(1) none")
    t.expect_equal_int(v1, 200)?

    var v2 = 0
    match buf.get(2):
        Option.some as r2:
            v2 = int<-r2.value
        Option.none:
            return t.fail("get(2) none")
    t.expect_equal_int(v2, 300)?

    t.expect(buf.earliest_tick() == 0, "earliest_tick == 0")?

    buf.push(1, 999)
    var v1b = 0
    match buf.get(1):
        Option.some as r1b:
            v1b = int<-r1b.value
        Option.none:
            return t.fail("get(1) after overwrite none")
    return t.expect_equal_int(v1b, 999)
