## Timer tests.
## Run via `mtc test test/mt/`.

import std.timer as time


@[test]
function test_timer_one_shot_fires() -> void:
    var tm = time.Timer.create(1.0, false)
    expect(not tm.step(0.4), "not yet at 0.4")
    expect(not tm.step(0.4), "not yet at 0.8")
    expect(tm.step(0.3), "fires at 1.1")



@[test]
function test_timer_one_shot_stops() -> void:
    var tm = time.Timer.create(1.0, false)
    expect(tm.step(1.5), "fires at 1.5")
    expect(not tm.active, "inactive after fire")
    expect(not tm.step(0.5), "no re-fire when inactive")



@[test]
function test_timer_repeating() -> void:
    var tm = time.Timer.create(1.0, true)
    var fires: int = 0
    var i: int = 0
    while i < 10:
        if tm.step(0.3):
            fires = fires + 1
        i = i + 1
    # 10 * 0.3 = 3.0 seconds → 3 fires
    expect(fires == 3, "repeating fires 3 times in 3s")



@[test]
function test_timer_repeating_residual() -> void:
    var tm = time.Timer.create(1.0, true)
    let f1 = tm.step(0.6)  # 0.6
    let f2 = tm.step(0.6)  # 0.6+0.6=1.2 → fire, residual 0.2
    expect(not f1, "no fire at 0.6")
    expect(f2, "fire at 1.2")
    # elapsed should now be ~0.2 (residual)
    expect(tm.progress() >= 0.19 and tm.progress() <= 0.21, "residual progress ~0.2")



@[test]
function test_timer_progress() -> void:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.5)
    let p = tm.progress()
    expect(p >= 0.24 and p <= 0.26, "progress at 0.25 after 0.5/2.0")



@[test]
function test_timer_time_left() -> void:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.3)
    let tl = tm.time_left()
    expect(tl >= 1.69 and tl <= 1.71, "1.7 left after 0.3")



@[test]
function test_timer_reset() -> void:
    var tm = time.Timer.create(1.0, false)
    tm.step(0.9)
    tm.reset()
    expect(tm.active, "active after reset")
    expect(tm.progress() <= 0.01, "progress reset")



@[test]
function test_timer_stop_resume() -> void:
    var tm = time.Timer.create(2.0, false)
    tm.step(0.5)
    tm.stop()
    expect(not tm.step(0.5), "no fire while stopped")
    tm.resume()
    expect(tm.active, "active after resume")
    expect(tm.time_left() >= 1.49, "still 1.5 left after resume")



@[test]
function test_timer_restart() -> void:
    var tm = time.Timer.create(1.0, false)
    tm.step(0.8)
    tm.restart(2.0)
    expect(tm.active, "active after restart")
    expect(tm.time_left() >= 1.99, "2.0 remaining after restart")



@[test]
function test_timer_pause() -> void:
    var tm = time.Timer.create(1.0, true)
    tm.pause()
    expect(not tm.active, "inactive after pause")
    expect(not tm.step(0.5), "no fire while paused")

