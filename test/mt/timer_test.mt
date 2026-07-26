## Timer tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.timer as time


@[test]
function test_timer_one_shot_fires() -> t.Check:
    var tm = time.Timer.create(1.0, false)
    t.expect(not tm.step(0.4), "not yet at 0.4")?
    t.expect(not tm.step(0.4), "not yet at 0.8")?
    t.expect(tm.step(0.3), "fires at 1.1")?

    return t.ok()


@[test]
function test_timer_one_shot_stops() -> t.Check:
    var tm = time.Timer.create(1.0, false)
    t.expect(tm.step(1.5), "fires at 1.5")?
    t.expect(not tm.active, "inactive after fire")?
    t.expect(not tm.step(0.5), "no re-fire when inactive")?

    return t.ok()


@[test]
function test_timer_repeating() -> t.Check:
    var tm = time.Timer.create(1.0, true)
    var fires: int = 0
    var i: int = 0
    while i < 10:
        if tm.step(0.3):
            fires = fires + 1
        i = i + 1
    # 10 * 0.3 = 3.0 seconds → 3 fires
    t.expect(fires == 3, "repeating fires 3 times in 3s")?

    return t.ok()


@[test]
function test_timer_repeating_residual() -> t.Check:
    var tm = time.Timer.create(1.0, true)
    let f1 = tm.step(0.6)  # 0.6
    let f2 = tm.step(0.6)  # 0.6+0.6=1.2 → fire, residual 0.2
    t.expect(not f1, "no fire at 0.6")?
    t.expect(f2, "fire at 1.2")?
    # elapsed should now be ~0.2 (residual)
    t.expect(tm.progress() >= 0.19 and tm.progress() <= 0.21, "residual progress ~0.2")?

    return t.ok()


@[test]
function test_timer_progress() -> t.Check:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.5)
    let p = tm.progress()
    t.expect(p >= 0.24 and p <= 0.26, "progress at 0.25 after 0.5/2.0")?

    return t.ok()


@[test]
function test_timer_time_left() -> t.Check:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.3)
    let tl = tm.time_left()
    t.expect(tl >= 1.69 and tl <= 1.71, "1.7 left after 0.3")?

    return t.ok()


@[test]
function test_timer_reset() -> t.Check:
    var tm = time.Timer.create(1.0, false)
    tm.step(0.9)
    tm.reset()
    t.expect(tm.active, "active after reset")?
    t.expect(tm.progress() <= 0.01, "progress reset")?

    return t.ok()


@[test]
function test_timer_stop_resume() -> t.Check:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.5)
    tm.stop()
    t.expect(not tm.step(0.5), "no fire while stopped")?
    tm.resume()
    t.expect(tm.active, "active after resume")?
    t.expect(tm.time_left() >= 1.49, "still 1.5 left after resume")?

    return t.ok()


@[test]
function test_timer_restart() -> t.Check:
    var tm = time.Timer.create(1.0, false)
    tm.step(0.8)
    tm.restart(2.0)
    t.expect(tm.active, "active after restart")?
    t.expect(tm.time_left() >= 1.99, "2.0 remaining after restart")?

    return t.ok()


@[test]
function test_timer_pause() -> t.Check:
    var tm = time.Timer.create(1.0, true)
    tm.pause()
    t.expect(not tm.active, "inactive after pause")?
    t.expect(not tm.step(0.5), "no fire while paused")?

    return t.ok()
