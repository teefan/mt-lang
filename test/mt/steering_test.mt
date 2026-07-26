## Steering behavior tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.steering


function vec_approx(a: vec2, b: vec2, eps: float) -> bool:
    let dx = a.x - b.x
    let dy = a.y - b.y
    let adx = if dx < 0.0: -dx else: dx
    let ady = if dy < 0.0: -dy else: dy
    return adx < eps and ady < eps


@[test]
function test_steering_seek() -> t.Check:
    let pos = vec2(x = 0.0, y = 0.0)
    let vel = vec2(x = 0.0, y = 0.0)
    let target = vec2(x = 10.0, y = 0.0)
    let f = vec2.seek(pos, vel, target, 5.0)
    # desired_vel = normalize(10,0) * 5 = (5,0), force = (5,0) - (0,0) = (5,0)
    t.expect(vec_approx(f, vec2(x = 5.0, y = 0.0), 0.01), "seek toward target")?

    return t.ok()


@[test]
function test_steering_flee() -> t.Check:
    let pos = vec2(x = 5.0, y = 0.0)
    let vel = vec2(x = 0.0, y = 0.0)
    let threat = vec2(x = 0.0, y = 0.0)
    let f = vec2.flee(pos, vel, threat, 5.0)
    # desired = (5,0) - (0,0) = (5,0), normalized = (1,0), *5 = (5,0)
    t.expect(f.x > 0.0, "flee moves away from threat")?

    return t.ok()


@[test]
function test_steering_arrive() -> t.Check:
    let pos = vec2(x = 0.0, y = 0.0)
    let vel = vec2(x = 10.0, y = 0.0)
    let target = vec2(x = 5.0, y = 0.0)
    let f = vec2.arrive(pos, vel, target, 10.0, 5.0)
    # distance=5, slowing=5, speed=10, vel=(10,0), desired=(10,0), force=(0,0)
    t.expect(vec_approx(f, vec2(x = 0.0, y = 0.0), 0.01), "arrive matches velocity at distance")?

    return t.ok()


@[test]
function test_steering_separation() -> t.Check:
    let pos = vec2(x = 0.0, y = 0.0)
    var neighbors = array[vec2, 2](
        vec2(x = 1.0, y = 0.0),
        vec2(x = 2.0, y = 0.0)
    )
    let sp = span[vec2](data = ptr_of(neighbors[0]), len = 2)
    let f = vec2.separation(pos, sp, 5.0)
    # Both neighbors are within separation radius
    t.expect(f.x < 0.0, "separation pushes away from neighbors")?

    return t.ok()


@[test]
function test_steering_alignment() -> t.Check:
    let vel = vec2(x = 0.0, y = 0.0)
    var nvels = array[vec2, 2](
        vec2(x = 1.0, y = 0.0),
        vec2(x = 1.0, y = 0.0)
    )
    let sp = span[vec2](data = ptr_of(nvels[0]), len = 2)
    let f = vec2.alignment(vel, sp)
    # avg velocity = (1,0), force = (1,0) - (0,0) = (1,0)
    t.expect(vec_approx(f, vec2(x = 1.0, y = 0.0), 0.01), "align to neighbors")?

    return t.ok()


@[test]
function test_steering_cohesion() -> t.Check:
    let pos = vec2(x = 0.0, y = 0.0)
    var npos = array[vec2, 2](
        vec2(x = 10.0, y = 0.0),
        vec2(x = 20.0, y = 0.0)
    )
    let sp = span[vec2](data = ptr_of(npos[0]), len = 2)
    let f = vec2.cohesion(pos, sp, 30.0)
    # both within radius, center = (15,0), desired = (15,0) - (0,0) = (15,0)
    t.expect(f.x > 0.0, "cohesion toward center")?

    return t.ok()


@[test]
function test_steering_limit() -> t.Check:
    let f = vec2(x = 10.0, y = 0.0)
    let capped = vec2.limit(f, 5.0)
    t.expect(vec_approx(capped, vec2(x = 5.0, y = 0.0), 0.01), "force capped at max")?

    return t.ok()


@[test]
function test_steering_limit_under() -> t.Check:
    let f = vec2(x = 3.0, y = 0.0)
    let capped = vec2.limit(f, 5.0)
    t.expect(vec_approx(capped, f, 0.01), "force unchanged when under limit")?

    return t.ok()
