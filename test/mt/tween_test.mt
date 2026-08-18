## Tween tests.
## Run via `mtc test test/mt/`.

import std.tween as tw


@[test]
function test_tween_linear() -> void:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.5)
    let v = tween.value()
    expect(v >= 49.9 and v <= 50.1, "linear at half")



@[test]
function test_tween_completes() -> void:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.ease_out_cubic)
    tween.step(1.5)
    expect(not tween.active, "tween inactive after completion")



@[test]
function test_tween_reaches_end() -> void:
    var tween = tw.Tween.create(0.0, 100.0, 0.5, tw.Easing.linear)
    tween.step(1.0)
    let v = tween.value()
    expect(v >= 99.9 and v <= 100.1, "tween reaches to value")



@[test]
function test_tween_start_at_from() -> void:
    var tween = tw.Tween.create(10.0, 90.0, 1.0, tw.Easing.linear)
    let v = tween.value()
    expect(v >= 9.9 and v <= 10.1, "tween starts at from value")



@[test]
function test_tween_reset() -> void:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.8)
    tween.reset(50.0, 150.0, 2.0, tw.Easing.ease_out_cubic)
    expect(tween.active, "tween active after reset")
    let v = tween.value()
    expect(v >= 49.9 and v <= 50.1, "tween at new from after reset")



@[test]
function test_tween_stop() -> void:
    var tween = tw.Tween.create(0.0, 100.0, 1.0, tw.Easing.linear)
    tween.step(0.3)
    tween.stop()
    expect(not tween.active, "tween inactive after stop")



@[test]
function test_easing_quad_in() -> void:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_quad, 0.5)
    expect(v >= 0.24 and v <= 0.26, "quad in at 0.5 is 0.25")



@[test]
function test_easing_quad_out() -> void:
    let v = tw.Tween.apply_easing(tw.Easing.ease_out_quad, 0.5)
    expect(v >= 0.74 and v <= 0.76, "quad out at 0.5 is 0.75")



@[test]
function test_easing_sine_in() -> void:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_sine, 0.5)
    # 1 - cos(pi/4) ≈ 1 - 0.707 = 0.293
    expect(v > 0.28 and v < 0.31, "sine in at 0.5")



@[test]
function test_easing_bounce_out_end() -> void:
    let v = tw.Tween.apply_easing(tw.Easing.ease_out_bounce, 1.0)
    expect(v >= 0.99 and v <= 1.01, "bounce out ends at 1.0")



@[test]
function test_easing_linear_endpoints() -> void:
    let v0 = tw.Tween.apply_easing(tw.Easing.linear, 0.0)
    let v1 = tw.Tween.apply_easing(tw.Easing.linear, 1.0)
    expect(v0 >= -0.01 and v0 <= 0.01, "linear at 0")
    expect(v1 >= 0.99 and v1 <= 1.01, "linear at 1")



@[test]
function test_easing_cubic_in_out() -> void:
    let v = tw.Tween.apply_easing(tw.Easing.ease_in_out_cubic, 0.5)
    expect(v >= 0.49 and v <= 0.51, "cubic in_out at 0.5 is 0.5")



# ── multi-type tween tests ──

@[test]
function test_tween2_linear() -> void:
    var t2 = tw.Tween2.create(
        vec2(x = 0.0, y = 0.0),
        vec2(x = 10.0, y = 20.0),
        1.0,
        tw.Easing.linear
    )
    t2.step(0.5)
    let v = t2.value()
    expect(v.x >= 4.9 and v.x <= 5.1, "tween2 x at 0.5")
    expect(v.y >= 9.9 and v.y <= 10.1, "tween2 y at 0.5")


@[test]
function test_tween2_reset() -> void:
    var t2 = tw.Tween2.create(
        vec2(x = 0.0, y = 0.0),
        vec2(x = 100.0, y = 100.0),
        1.0,
        tw.Easing.linear
    )
    t2.step(0.8)
    t2.reset(vec2(x = 50.0, y = 50.0), vec2(x = 150.0, y = 150.0), 2.0, tw.Easing.ease_out_cubic)
    let v = t2.value()
    expect(v.x >= 49.9 and v.x <= 50.1, "tween2 reset from")


@[test]
function test_tween3_create() -> void:
    var t2 = tw.Tween3.create(
        vec3(x = 0.0, y = 0.0, z = 0.0),
        vec3(x = 10.0, y = 20.0, z = 30.0),
        1.0,
        tw.Easing.linear
    )
    t2.step(1.5)
    let v = t2.value()
    expect(v.x >= 9.9 and v.x <= 10.1, "tween3 x complete")
    expect(v.z >= 29.9 and v.z <= 30.1, "tween3 z complete")


@[test]
function test_tween4_create() -> void:
    var t2 = tw.Tween4.create(
        vec4(x = 0.0, y = 0.0, z = 0.0, w = 0.0),
        vec4(x = 1.0, y = 2.0, z = 3.0, w = 4.0),
        0.5,
        tw.Easing.linear
    )
    t2.step(1.0)
    let v = t2.value()
    expect(v.w >= 3.9 and v.w <= 4.1, "tween4 w complete")

@[test]
function test_tween2_stop() -> void:
    var t2 = tw.Tween2.create(
        vec2(x = 0.0, y = 0.0),
        vec2(x = 100.0, y = 100.0),
        1.0,
        tw.Easing.linear
    )
    t2.step(0.3)
    t2.stop()
    expect(not t2.x.active, "tween2 x stopped")
    expect(not t2.y.active, "tween2 y stopped")
