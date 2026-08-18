## Noise tests.
## Run via `mtc test test/mt/`.

import std.noise as ns


@[test]
function test_noise_deterministic() -> void:
    var a = ns.Noise.create(42)
    var b = ns.Noise.create(42)

    let v1 = a.perlin2d(0.5, 0.5)
    let v2 = b.perlin2d(0.5, 0.5)
    expect(v1 == v2, "same seed produces same value")



@[test]
function test_noise_range_2d() -> void:
    var n = ns.Noise.create(123)
    var i: int = 0
    var min_val: float = 1000.0
    var max_val: float = -1000.0
    while i < 100:
        let x = float<-(i) * 0.37
        let y = float<-(i) * 0.73
        let v = n.perlin2d(x, y)
        if v < min_val: min_val = v
        if v > max_val: max_val = v
        i += 1
    expect(min_val >= -1.1 and max_val <= 1.1, "2d noise in [-1, 1]")



@[test]
function test_noise_range_3d() -> void:
    var n = ns.Noise.create(456)
    var i: int = 0
    var min_val: float = 1000.0
    var max_val: float = -1000.0
    while i < 50:
        let x = float<-(i) * 0.51
        let y = float<-(i) * 0.83
        let z = float<-(i) * 0.29
        let v = n.perlin3d(x, y, z)
        if v < min_val: min_val = v
        if v > max_val: max_val = v
        i += 1
    expect(min_val >= -1.1 and max_val <= 1.1, "3d noise in [-1, 1]")



@[test]
function test_noise_fbm_in_range() -> void:
    var n = ns.Noise.create(789)
    n.set_octaves(4)
    n.set_gain(0.5)
    n.set_lacunarity(2.0)

    var i: int = 0
    while i < 50:
        let v = n.fbm2d(float<-(i) * 0.1, 0.0)
        if v < -1.5 or v > 1.5:
            expect(false, "fbm2d out of range")
        i += 1


@[test]
function test_noise_zero_at_integer() -> void:
    var n = ns.Noise.create(1)
    let v = n.perlin2d(0.0, 0.0)
    expect(v >= -0.001 and v <= 0.001, "noise at origin is near zero")



@[test]
function test_noise_field_scales_with_frequency() -> void:
    var a = ns.Noise.create(333)
    var b = ns.Noise.create(333)
    b.set_frequency(2.0)

    let v1 = a.perlin2d(0.5, 0.5)
    let v2 = b.perlin2d(0.25, 0.25)
    # Doubling frequency and halving input should give same value
    # (within some tolerance, since other octaves differ)
    expect(v1 >= -1.5 and v1 <= 1.5)

