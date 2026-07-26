## Color utilities — RGBA conversion, blending, and presets.
##
## Provides an RGBA Color struct compatible with raylib/FBO
## layouts, plus HSL/HSV conversion, hex parsing, alpha
## blending, and common named-color constants.
##
##   import std.color as clr
##   let c = clr.Color.from_hsl(210.0, 0.8, 0.6)
##   let blended = c.alpha_blend(clr.WHITE)

public struct Color:
    r: ubyte
    g: ubyte
    b: ubyte
    a: ubyte


public const WHITE:  Color = Color(r = 255, g = 255, b = 255, a = 255)
public const BLACK:  Color = Color(r = 0,   g = 0,   b = 0,   a = 255)
public const RED:    Color = Color(r = 255, g = 0,   b = 0,   a = 255)
public const GREEN:  Color = Color(r = 0,   g = 255, b = 0,   a = 255)
public const BLUE:   Color = Color(r = 0,   g = 0,   b = 255, a = 255)
public const YELLOW: Color = Color(r = 255, g = 255, b = 0,   a = 255)
public const CYAN:   Color = Color(r = 0,   g = 255, b = 255, a = 255)
public const MAGENTA:Color = Color(r = 255, g = 0,   b = 255, a = 255)
public const GRAY:   Color = Color(r = 128, g = 128, b = 128, a = 255)
public const ORANGE: Color = Color(r = 255, g = 165, b = 0,   a = 255)
public const PINK:   Color = Color(r = 255, g = 192, b = 203, a = 255)
public const PURPLE: Color = Color(r = 128, g = 0,   b = 128, a = 255)
public const TRANSPARENT: Color = Color(r = 0, g = 0, b = 0, a = 0)


# ── math helpers ──

function fmin(a: float, b: float) -> float:
    if a < b: return a
    return b


function fmax(a: float, b: float) -> float:
    if a > b: return a
    return b


function fabs(x: float) -> float:
    if x < 0.0: return -x
    return x


function fmod(x: float, m: float) -> float:
    # x - floor(x / m) * m
    let div = x / m
    let fl = float<-(int<-(div))
    if div < 0.0 and float<-(int<-(div)) != div:
        return x - (fl - 1.0) * m
    return x - fl * m


# ── public API ──

extending Color:
    public static function from_rgba(r: ubyte, g: ubyte, b: ubyte, a: ubyte) -> Color:
        return Color(r = r, g = g, b = b, a = a)


    public static function from_hsl(h: float, s: float, l: float) -> Color:
        # h: 0..360, s: 0..1, l: 0..1
        var hh = fmod(h, 360.0)
        if hh < 0.0: hh = hh + 360.0

        let c = (1.0 - fabs(2.0 * l - 1.0)) * s
        let x = c * (1.0 - fabs(fmod(hh / 60.0, 2.0) - 1.0))
        let m = l - c / 2.0

        var r1: float = 0.0
        var g1: float = 0.0
        var b1: float = 0.0

        if hh < 60.0:
            r1 = c
            g1 = x
        else if hh < 120.0:
            r1 = x
            g1 = c
        else if hh < 180.0:
            g1 = c
            b1 = x
        else if hh < 240.0:
            g1 = x
            b1 = c
        else if hh < 300.0:
            r1 = x
            b1 = c
        else:
            r1 = c
            b1 = x

        return Color(
            r = ubyte<-((r1 + m) * 255.0),
            g = ubyte<-((g1 + m) * 255.0),
            b = ubyte<-((b1 + m) * 255.0),
            a = 255
        )


    public static function from_hsv(h: float, s: float, v: float) -> Color:
        var hh = fmod(h, 360.0)
        if hh < 0.0: hh = hh + 360.0

        let c = v * s
        let x = c * (1.0 - fabs(fmod(hh / 60.0, 2.0) - 1.0))
        let m = v - c

        var r1: float = 0.0
        var g1: float = 0.0
        var b1: float = 0.0

        if hh < 60.0:
            r1 = c
            g1 = x
        else if hh < 120.0:
            r1 = x
            g1 = c
        else if hh < 180.0:
            g1 = c
            b1 = x
        else if hh < 240.0:
            g1 = x
            b1 = c
        else if hh < 300.0:
            r1 = x
            b1 = c
        else:
            r1 = c
            b1 = x

        return Color(
            r = ubyte<-((r1 + m) * 255.0),
            g = ubyte<-((g1 + m) * 255.0),
            b = ubyte<-((b1 + m) * 255.0),
            a = 255
        )


    public function to_hsl() -> (float, float, float):
        let rf = float<-(this.r) / 255.0
        let gf = float<-(this.g) / 255.0
        let bf = float<-(this.b) / 255.0

        let mx = fmax(fmax(rf, gf), bf)
        let mn = fmin(fmin(rf, gf), bf)
        let delta = mx - mn

        let l = (mx + mn) / 2.0

        var h: float = 0.0
        let s = if delta == 0.0: 0.0 else: delta / (1.0 - fabs(2.0 * l - 1.0))

        if delta != 0.0:
            if mx == rf:
                h = fmod((gf - bf) / delta, 6.0)
            else if mx == gf:
                h = (bf - rf) / delta + 2.0
            else:
                h = (rf - gf) / delta + 4.0
            h = h * 60.0
            if h < 0.0:
                h = h + 360.0

        return (h, s, l)


    public function to_hsv() -> (float, float, float):
        let rf = float<-(this.r) / 255.0
        let gf = float<-(this.g) / 255.0
        let bf = float<-(this.b) / 255.0

        let mx = fmax(fmax(rf, gf), bf)
        let mn = fmin(fmin(rf, gf), bf)
        let delta = mx - mn

        var h: float = 0.0
        let s = if mx == 0.0: 0.0 else: delta / mx
        let v = mx

        if delta != 0.0:
            if mx == rf:
                h = fmod((gf - bf) / delta, 6.0)
            else if mx == gf:
                h = (bf - rf) / delta + 2.0
            else:
                h = (rf - gf) / delta + 4.0
            h = h * 60.0
            if h < 0.0:
                h = h + 360.0

        return (h, s, v)


    public function lerp(target: Color, t: float) -> Color:
        let r = float<-(this.r) + (float<-(target.r) - float<-(this.r)) * t
        let g = float<-(this.g) + (float<-(target.g) - float<-(this.g)) * t
        let b = float<-(this.b) + (float<-(target.b) - float<-(this.b)) * t
        let a = float<-(this.a) + (float<-(target.a) - float<-(this.a)) * t
        return Color(r = ubyte<-(r), g = ubyte<-(g), b = ubyte<-(b), a = ubyte<-(a))


    public function alpha_blend(background: Color) -> Color:
        if this.a == 0:
            return background
        if this.a == 255:
            return this

        let sa = float<-(this.a) / 255.0
        let da = float<-(background.a) / 255.0

        let r_out = float<-(this.r) * sa + float<-(background.r) * da * (1.0 - sa)
        let g_out = float<-(this.g) * sa + float<-(background.g) * da * (1.0 - sa)
        let b_out = float<-(this.b) * sa + float<-(background.b) * da * (1.0 - sa)
        let a_out = sa + da * (1.0 - sa)

        return Color(
            r = ubyte<-(r_out),
            g = ubyte<-(g_out),
            b = ubyte<-(b_out),
            a = ubyte<-(a_out * 255.0)
        )


    public function scale(factor: float) -> Color:
        let r = fmin(fmax(float<-(this.r) * factor, 0.0), 255.0)
        let g = fmin(fmax(float<-(this.g) * factor, 0.0), 255.0)
        let b = fmin(fmax(float<-(this.b) * factor, 0.0), 255.0)
        return Color(r = ubyte<-(r), g = ubyte<-(g), b = ubyte<-(b), a = this.a)


    public function multiply(other: Color) -> Color:
        let r = ubyte<-(int<-((int<-(this.r) * int<-(other.r)) / 255))
        let g = ubyte<-(int<-((int<-(this.g) * int<-(other.g)) / 255))
        let b = ubyte<-(int<-((int<-(this.b) * int<-(other.b)) / 255))
        return Color(r = r, g = g, b = b, a = this.a)


    public function with_alpha(a: ubyte) -> Color:
        return Color(r = this.r, g = this.g, b = this.b, a = a)