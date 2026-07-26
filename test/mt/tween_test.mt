## Tween tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.tween as tw


@[test]
function test_tween_linear() -> t.Check:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.5)
    let v = tween.value()
    t.expect(v >= 49.9 and v <= 50.1, "linear at half")?

    return t.ok()


@[test]
function test_tween_completes() -> t.Check:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.ease_out_cubic)
    tween.step(1.5)
    t.expect(not tween.active, "tween inactive after completion")?

    return t.ok()


@[test]
function test_tween_reaches_end() -> t.Check:
    var tween = tw.Tween.create(0.0, 100.0, 0.5, tw.Easing.linear)
    tween.step(1.0)
    let v = tween.value()
    t.expect(v >= 99.9 and v <= 100.1, "tween reaches to value")?

    return t.ok()


@[test]
function test_tween_start_at_from() -> t.Check:
    var tween = tw.Tween.create(10.0, 90.0, 1.0, tw.Easing.linear)
    let v = tween.value()
    t.expect(v >= 9.9 and v <= 10.1, "tween starts at from value")?

    return t.ok()


@[test]
function test_tween_reset() -> t.Check:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.8)
    tween.reset(50.0, 150.0, 2.0, tw.Easing.ease_out_cubic)
    t.expect(tween.active, "tween active after reset")?
    let v = tween.value()
    t.expect(v >= 49.9 and v <= 50.1, "tween at new from after reset")?

    return t.ok()


@[test]
function test_tween_stop() -> t.Check:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.3)
    tween.stop()
    t.expect(not tween.active, "tween inactive after stop")?

    return t.ok()


@[test]
function test_easing_quad_in() -> t.Check:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_quad, 0.5)
    t.expect(v >= 0.24 and v <= 0.26, "quad in at 0.5 is 0.25")?

    return t.ok()


@[test]
function test_easing_quad_out() -> t.Check:
    let v = tw.Tween.apply_easing(tw.Easing.ease_out_quad, 0.5)
    t.expect(v >= 0.74 and v <= 0.76, "quad out at 0.5 is 0.75")?

    return t.ok()


@[test]
function test_easing_sine_in() -> t.Check:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_sine, 0.5)
    # 1 - cos(pi/4) ≈ 1 - 0.707 = 0.293
    t.expect(v > 0.28 and v < 0.31, "sine in at 0.5")?

    return t.ok()


@[test]
function test_easing_bounce_out_end() -> t.Check:
    let v = tw.Tween.apply_easing(tw.Easing.ease_out_bounce, 1.0)
    t.expect(v >= 0.99 and v <= 1.01, "bounce out ends at 1.0")?

    return t.ok()


@[test]
function test_easing_linear_endpoints() -> t.Check:
    let v0 = tw.Tween.apply_easing(tw.Easing.linear, 0.0)
    let v1 = tw.Tween.apply_easing(tw.Easing.linear, 1.0)
    t.expect(v0 >= -0.01 and v0 <= 0.01, "linear at 0")?
    t.expect(v1 >= 0.99 and v1 <= 1.01, "linear at 1")?

    return t.ok()


@[test]
function test_easing_cubic_in_out() -> t.Check:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_out_cubic, 0.5)
    t.expect(v >= 0.49 and v <= 0.51, "cubic in_out at 0.5 is 0.5")?

    return t.ok()
