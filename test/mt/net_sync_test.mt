# In-language tests for std.net.sync (migrated from
# test/std/std_sync_test.rb, run by `mtc test`).

import std.net.sync as sync
import std.vec as vec

@[test]
function test_sync_value_dirty_tracking() -> void:
    var hp = sync.SyncValue[float](value = 100.0, dirty = false)
    expect(not hp.dirty)
    hp.set(90.0)
    expect(hp.dirty)
    expect(hp.get() == 90.0, "get == 90.0")
    hp.mark_clean()
    expect(not hp.dirty)
    expect(hp.get() == 90.0, "get == 90.0 after clean")


@[test]
function test_sync_value_with_uint() -> void:
    var score = sync.SyncValue[uint](value = 0, dirty = false)
    expect(not score.has_changed())
    score.set(42)
    expect(score.has_changed())
    expect(score.get() == 42, "get == 42")
    score.mark_clean()
    expect(not score.has_changed())
    expect(score.get() == 42, "get == 42 after clean")


@[test]
function test_sync_list_push_and_length() -> void:
    var list = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)
    defer: list.items.release()

    expect(not list.dirty)
    expect(list.len() == 0, "len == 0")

    list.push(10)
    expect(list.dirty)
    expect(list.len() == 1, "len == 1")

    let entity_ptr = list.get(0) else:
        expect(false, "get(0) none")
        return
    var first = 0
    unsafe:
        first = int<-read(entity_ptr)
    expect_eq(first, 10)

    list.mark_clean()
    expect(not list.dirty)

    list.clear()
    expect(list.dirty)
    expect(list.len() == 0, "len == 0 after clear")


@[test]
function test_sync_list_multiple_items() -> void:
    var events = sync.SyncList[uint](items = vec.Vec[uint].create(), dirty = false)
    defer: events.items.release()

    events.push(100)
    events.push(200)
    events.push(300)

    expect(events.len() == 3, "len == 3")
    expect(events.dirty)

    let p0 = events.get(0) else:
        expect(false, "get(0) none")
        return
    let p1 = events.get(1) else:
        expect(false, "get(1) none")
        return
    let p2 = events.get(2) else:
        expect(false, "get(2) none")
        return
    var v0 = 0
    var v1 = 0
    var v2 = 0
    unsafe:
        v0 = int<-read(p0)
        v1 = int<-read(p1)
        v2 = int<-read(p2)
    expect_eq(v0, 100)
    expect_eq(v1, 200)
    expect_eq(v2, 300)

    events.mark_clean()
    expect(not events.dirty)


@[test]
function test_sync_lerp_interpolates() -> void:
    var lerp = sync.Lerp(
        previous = 0.0,
        target = 100.0,
        elapsed = 0.0,
        duration = 1.0
    )

    expect(lerp.current() == 0.0, "current == 0 at t=0")

    lerp.tick(0.5)
    let mid = lerp.current()
    expect(mid >= 49.0 and mid <= 51.0, "current ~50 at t=0.5")

    lerp.tick(0.5)
    expect(lerp.current() == 100.0, "current == 100 at t=1")
    expect(lerp.has_arrived())

    lerp.set_target(200.0, 1.0)
    expect(lerp.current() == 100.0, "current == 100 after set_target")

    lerp.tick(1.0)
    expect(lerp.current() == 200.0, "current == 200 after tick")


@[test]
function test_sync_compressed_u16_roundtrip() -> void:
    var c = sync.CompressedUshort(min = 0.0, max = 1000.0)

    let original: float = 500.0
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)
    expect(decoded >= 499.9 and decoded <= 500.1, "500 round-trips within precision")

    var lo = c.decode(c.encode(0.0))
    expect(lo >= -0.1 and lo <= 0.1, "min round-trips")

    var hi = c.decode(c.encode(1000.0))
    expect(hi >= 999.9 and hi <= 1000.1, "max round-trips")

    var clamped = c.decode(c.encode(-500.0))
    expect(clamped >= -0.1 and clamped <= 0.1, "below min clamps to min")


@[test]
function test_sync_compressed_u8_roundtrip() -> void:
    var c = sync.CompressedUbyte(min = -1.0, max = 1.0)

    let original: float = 0.5
    var encoded = c.encode(original)
    var decoded = c.decode(encoded)
    expect(decoded >= 0.48 and decoded <= 0.52, "0.5 round-trips within precision")

    var zero_value = c.decode(c.encode(0.0))
    expect(zero_value >= -0.02 and zero_value <= 0.02, "zero stays near zero")


@[test]
function test_sync_tick_buffer_push_and_get() -> void:
    var buf = sync.TickBuffer[uint](
        entries = vec.Vec[uint].create(),
        base_tick = 0
    )
    defer: buf.entries.release()

    buf.push(0, 100)
    buf.push(1, 200)
    buf.push(2, 300)

    var v0 = 0
    match buf.get(0):
        Option.some as r0:
            v0 = int<-r0.value
        Option.none:
            expect(false, "get(0) none")
    expect_eq(v0, 100)

    var v1 = 0
    match buf.get(1):
        Option.some as r1:
            v1 = int<-r1.value
        Option.none:
            expect(false, "get(1) none")
    expect_eq(v1, 200)

    var v2 = 0
    match buf.get(2):
        Option.some as r2:
            v2 = int<-r2.value
        Option.none:
            expect(false, "get(2) none")
    expect_eq(v2, 300)

    expect(buf.earliest_tick() == 0, "earliest_tick == 0")

    buf.push(1, 999)
    var v1b = 0
    match buf.get(1):
        Option.some as r1b:
            v1b = int<-r1b.value
        Option.none:
            expect(false, "get(1) after overwrite none")
    expect_eq(v1b, 999)
