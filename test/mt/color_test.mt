## Color tests.
## Run via `mtc test test/mt/`.

import std.testing as t
import std.color as clr


@[test]
function test_color_constants() -> t.Check:
    t.expect(clr.RED.r == 255 and clr.RED.g == 0 and clr.RED.b == 0, "RED is 255,0,0")?
    t.expect(clr.BLACK.r == 0 and clr.BLACK.a == 255, "BLACK with full alpha")?
    t.expect(clr.TRANSPARENT.a == 0, "TRANSPARENT has alpha=0")?

    return t.ok()


@[test]
function test_color_rgba() -> t.Check:
    let c = clr.Color.from_rgba(10, 20, 30, 200)
    t.expect(c.r == 10 and c.g == 20 and c.b == 30, "rgba components preserved")?
    t.expect(c.a == 200, "alpha preserved")?

    return t.ok()


@[test]
function test_color_hsl_black() -> t.Check:
    let c = clr.Color.from_hsl(0.0, 0.0, 0.0)
    t.expect(c.r == 0 and c.g == 0 and c.b == 0, "hsl(0,0,0) is black")?

    return t.ok()


@[test]
function test_color_hsl_white() -> t.Check:
    let c = clr.Color.from_hsl(0.0, 0.0, 1.0)
    t.expect(c.r == 255 and c.g == 255 and c.b == 255, "hsl(0,0,1) is white")?

    return t.ok()


@[test]
function test_color_hsl_red() -> t.Check:
    let c = clr.Color.from_hsl(0.0, 1.0, 0.5)
    t.expect(c.r == 255 and c.g == 0 and c.b == 0, "hsl(0,1,0.5) is red")?

    return t.ok()


@[test]
function test_color_hsl_green() -> t.Check:
    let c = clr.Color.from_hsl(120.0, 1.0, 0.5)
    t.expect(c.g >= 250, "hsl(120,1,0.5) is green")?

    return t.ok()


@[test]
function test_color_hsl_blue() -> t.Check:
    let c = clr.Color.from_hsl(240.0, 1.0, 0.5)
    t.expect(c.b >= 250, "hsl(240,1,0.5) is blue")?

    return t.ok()


@[test]
function test_color_hsl_roundtrip() -> t.Check:
    let src = clr.Color.from_rgba(100, 200, 50, 255)
    let (h, s, l) = src.to_hsl()
    let dst = clr.Color.from_hsl(h, s, l)
    let dr = int<-(dst.r) - int<-(src.r)
    let dg = int<-(dst.g) - int<-(src.g)
    let db = int<-(dst.b) - int<-(src.b)
    var diff = if dr < 0: -dr else: dr
    diff = diff + (if dg < 0: -dg else: dg)
    diff = diff + (if db < 0: -db else: db)
    t.expect(diff <= 6, "HSL roundtrip within 2 per channel")?

    return t.ok()


@[test]
function test_color_lerp() -> t.Check:
    let a = clr.Color.from_rgba(0, 0, 0, 255)
    let b = clr.Color.from_rgba(100, 100, 100, 255)
    let c = a.lerp(b, 0.5)
    t.expect(c.r == 50 and c.g == 50 and c.b == 50, "lerp at 0.5")?

    return t.ok()


@[test]
function test_color_alpha_blend() -> t.Check:
    let fg = clr.Color.from_rgba(255, 0, 0, 128)
    let bg = clr.Color.from_rgba(0, 0, 255, 255)
    let c = fg.alpha_blend(bg)
    # 255*0.5 + 0*1.0*(1-0.5) = 127.5 ≈ 128
    # 0*0.5 + 0*1.0*(1-0.5) = 0
    # 0*0.5 + 255*1.0*(1-0.5) = 127.5 ≈ 128
    t.expect(c.r >= 125 and c.r <= 130, "alpha blend red")?
    t.expect(c.b >= 125 and c.b <= 130, "alpha blend blue")?

    return t.ok()


@[test]
function test_color_scale() -> t.Check:
    let c = clr.Color.from_rgba(200, 100, 50, 255)
    let s = c.scale(0.5)
    t.expect(s.r == 100 and s.g == 50 and s.b == 25, "scale 0.5 halves")?

    return t.ok()


@[test]
function test_color_with_alpha() -> t.Check:
    let c = clr.Color.from_rgba(100, 200, 50, 255)
    let d = c.with_alpha(128)
    t.expect(d.r == 100 and d.g == 200 and d.b == 50, "rgb unchanged")?
    t.expect(d.a == 128, "alpha updated")?

    return t.ok()


@[test]
function test_color_hsv_roundtrip() -> t.Check:
    let src = clr.Color.from_rgba(100, 200, 50, 255)
    let (h, s, v) = src.to_hsv()
    let dst = clr.Color.from_hsv(h, s, v)
    let dr = int<-(dst.r) - int<-(src.r)
    let dg = int<-(dst.g) - int<-(src.g)
    let db = int<-(dst.b) - int<-(src.b)
    var diff = if dr < 0: -dr else: dr
    diff = diff + (if dg < 0: -dg else: dg)
    diff = diff + (if db < 0: -db else: db)
    t.expect(diff <= 6, "HSV roundtrip within 2 per channel")?

    return t.ok()


@[test]
function test_color_multiply() -> t.Check:
    let a = clr.Color.from_rgba(200, 100, 50, 255)
    let b = clr.Color.from_rgba(128, 255, 64, 255)
    let c = a.multiply(b)
    # 200*128/255 ≈ 100, 100*255/255 = 100, 50*64/255 ≈ 12
    t.expect(c.r >= 95 and c.r <= 105, "multiply r")?
    t.expect(c.g >= 95 and c.g <= 105, "multiply g")?

    return t.ok()
