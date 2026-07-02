import std.math as math

public const PI: float = 3.14159265358979323846

public const EASE_LINEAR_NONE: int = 0
public const EASE_LINEAR_IN: int = 1
public const EASE_LINEAR_OUT: int = 2
public const EASE_LINEAR_IN_OUT: int = 3
public const EASE_SINE_IN: int = 4
public const EASE_SINE_OUT: int = 5
public const EASE_SINE_IN_OUT: int = 6
public const EASE_CIRC_IN: int = 7
public const EASE_CIRC_OUT: int = 8
public const EASE_CIRC_IN_OUT: int = 9
public const EASE_CUBIC_IN: int = 10
public const EASE_CUBIC_OUT: int = 11
public const EASE_CUBIC_IN_OUT: int = 12
public const EASE_QUAD_IN: int = 13
public const EASE_QUAD_OUT: int = 14
public const EASE_QUAD_IN_OUT: int = 15
public const EASE_EXPO_IN: int = 16
public const EASE_EXPO_OUT: int = 17
public const EASE_EXPO_IN_OUT: int = 18
public const EASE_BACK_IN: int = 19
public const EASE_BACK_OUT: int = 20
public const EASE_BACK_IN_OUT: int = 21
public const EASE_BOUNCE_OUT: int = 22
public const EASE_BOUNCE_IN: int = 23
public const EASE_BOUNCE_IN_OUT: int = 24
public const EASE_ELASTIC_IN: int = 25
public const EASE_ELASTIC_OUT: int = 26
public const EASE_ELASTIC_IN_OUT: int = 27
public const EASING_NONE: int = 28


function sinf(value: float) -> float:
    return float<-math.sin(double<-value)


function cosf(value: float) -> float:
    return float<-math.cos(double<-value)


function sqrtf(value: float) -> float:
    return float<-math.sqrt(double<-value)


function powf(base: float, exponent: float) -> float:
    return float<-math.pow(double<-base, double<-exponent)


public function linear_none(t: float, b: float, c: float, d: float) -> float:
    return (c * t / d) + b


public function linear_in(t: float, b: float, c: float, d: float) -> float:
    return linear_none(t, b, c, d)


public function linear_out(t: float, b: float, c: float, d: float) -> float:
    return linear_none(t, b, c, d)


public function linear_in_out(t: float, b: float, c: float, d: float) -> float:
    return linear_none(t, b, c, d)


public function sine_in(t: float, b: float, c: float, d: float) -> float:
    return (-c * cosf((t / d) * (PI / 2.0)) + c + b)


public function sine_out(t: float, b: float, c: float, d: float) -> float:
    return (c * sinf((t / d) * (PI / 2.0)) + b)


public function sine_in_out(t: float, b: float, c: float, d: float) -> float:
    return (-c / 2.0 * (cosf(PI * t / d) - 1.0) + b)


public function circ_in(t: float, b: float, c: float, d: float) -> float:
    let current = t / d
    return (-c * (sqrtf(1.0 - current * current) - 1.0) + b)


public function circ_out(t: float, b: float, c: float, d: float) -> float:
    let current = (t / d) - 1.0
    return (c * sqrtf(1.0 - current * current) + b)


public function circ_in_out(t: float, b: float, c: float, d: float) -> float:
    var current = t / (d / 2.0)
    if current < 1.0:
        return (-c / 2.0 * (sqrtf(1.0 - current * current) - 1.0) + b)

    current -= 2.0
    return (c / 2.0 * (sqrtf(1.0 - current * current) + 1.0) + b)


public function cubic_in(t: float, b: float, c: float, d: float) -> float:
    let current = t / d
    return (c * current * current * current + b)


public function cubic_out(t: float, b: float, c: float, d: float) -> float:
    let current = (t / d) - 1.0
    return (c * (current * current * current + 1.0) + b)


public function cubic_in_out(t: float, b: float, c: float, d: float) -> float:
    var current = t / (d / 2.0)
    if current < 1.0:
        return (c / 2.0 * current * current * current + b)

    current -= 2.0
    return (c / 2.0 * (current * current * current + 2.0) + b)


public function quad_in(t: float, b: float, c: float, d: float) -> float:
    let current = t / d
    return (c * current * current + b)


public function quad_out(t: float, b: float, c: float, d: float) -> float:
    let current = t / d
    return (-c * current * (current - 2.0) + b)


public function quad_in_out(t: float, b: float, c: float, d: float) -> float:
    let current = t / (d / 2.0)
    if current < 1.0:
        return (c / 2.0 * current * current + b)

    return (-c / 2.0 * (((current - 1.0) * (current - 3.0)) - 1.0) + b)


public function expo_in(t: float, b: float, c: float, d: float) -> float:
    if t == 0.0:
        return b

    return (c * powf(2.0, 10.0 * ((t / d) - 1.0)) + b)


public function expo_out(t: float, b: float, c: float, d: float) -> float:
    if t == d:
        return b + c

    return (c * (-powf(2.0, (-10.0 * t) / d) + 1.0) + b)


public function expo_in_out(t: float, b: float, c: float, d: float) -> float:
    if t == 0.0:
        return b
    if t == d:
        return b + c

    let current = t / (d / 2.0)
    if current < 1.0:
        return (c / 2.0 * powf(2.0, 10.0 * (current - 1.0)) + b)

    return (c / 2.0 * (-powf(2.0, -10.0 * (current - 1.0)) + 2.0) + b)


public function back_in(t: float, b: float, c: float, d: float) -> float:
    let s = 1.70158
    let current = t / d
    return (c * current * current * (((s + 1.0) * current) - s) + b)


public function back_out(t: float, b: float, c: float, d: float) -> float:
    let s = 1.70158
    let current = (t / d) - 1.0
    return (c * (current * current * (((s + 1.0) * current) + s) + 1.0) + b)


public function back_in_out(t: float, b: float, c: float, d: float) -> float:
    var s: float = 1.70158
    var current = t / (d / 2.0)
    if current < 1.0:
        s *= 1.525
        return (c / 2.0 * (current * current * (((s + 1.0) * current) - s)) + b)

    current -= 2.0
    s *= 1.525
    return (c / 2.0 * (current * current * (((s + 1.0) * current) + s) + 2.0) + b)


public function bounce_out(t: float, b: float, c: float, d: float) -> float:
    let current = t / d
    if current < (1.0 / 2.75):
        return (c * (7.5625 * current * current) + b)
    else if current < (2.0 / 2.75):
        let post_fix = current - (1.5 / 2.75)
        return (c * (7.5625 * post_fix * post_fix + 0.75) + b)
    else if current < (2.5 / 2.75):
        let post_fix = current - (2.25 / 2.75)
        return (c * (7.5625 * post_fix * post_fix + 0.9375) + b)

    let post_fix = current - (2.625 / 2.75)
    return (c * (7.5625 * post_fix * post_fix + 0.984375) + b)


public function bounce_in(t: float, b: float, c: float, d: float) -> float:
    return (c - bounce_out(d - t, 0.0, c, d) + b)


public function bounce_in_out(t: float, b: float, c: float, d: float) -> float:
    if t < d / 2.0:
        return (bounce_in(t * 2.0, 0.0, c, d) * 0.5 + b)

    return (bounce_out(t * 2.0 - d, 0.0, c, d) * 0.5 + c * 0.5 + b)


public function elastic_in(t: float, b: float, c: float, d: float) -> float:
    if t == 0.0:
        return b

    var current = t / d
    if current == 1.0:
        return b + c

    let p = d * 0.3
    let a = c
    let s = p / 4.0
    current -= 1.0
    let post_fix = a * powf(2.0, 10.0 * current)
    return (-(post_fix * sinf(((current * d) - s) * ((2.0 * PI) / p))) + b)


public function elastic_out(t: float, b: float, c: float, d: float) -> float:
    if t == 0.0:
        return b

    let current = t / d
    if current == 1.0:
        return b + c

    let p = d * 0.3
    let a = c
    let s = p / 4.0
    return (a * powf(2.0, -10.0 * current) * sinf(((current * d) - s) * ((2.0 * PI) / p)) + c + b)


public function elastic_in_out(t: float, b: float, c: float, d: float) -> float:
    if t == 0.0:
        return b

    var current = t / (d / 2.0)
    if current == 2.0:
        return b + c

    let p = d * (0.3 * 1.5)
    let a = c
    let s = p / 4.0

    if current < 1.0:
        current -= 1.0
        let post_fix = a * powf(2.0, 10.0 * current)
        return (-0.5 * (post_fix * sinf(((current * d) - s) * ((2.0 * PI) / p))) + b)

    current -= 1.0
    let post_fix = a * powf(2.0, -10.0 * current)
    return (post_fix * sinf(((current * d) - s) * ((2.0 * PI) / p)) * 0.5 + c + b)


public function no_ease(_t: float, b: float, _c: float, _d: float) -> float:
    return b


public function by_kind(kind: int, t: float, b: float, c: float, d: float) -> float:
    if kind == EASE_LINEAR_NONE:
        return linear_none(t, b, c, d)
    else if kind == EASE_LINEAR_IN:
        return linear_in(t, b, c, d)
    else if kind == EASE_LINEAR_OUT:
        return linear_out(t, b, c, d)
    else if kind == EASE_LINEAR_IN_OUT:
        return linear_in_out(t, b, c, d)
    else if kind == EASE_SINE_IN:
        return sine_in(t, b, c, d)
    else if kind == EASE_SINE_OUT:
        return sine_out(t, b, c, d)
    else if kind == EASE_SINE_IN_OUT:
        return sine_in_out(t, b, c, d)
    else if kind == EASE_CIRC_IN:
        return circ_in(t, b, c, d)
    else if kind == EASE_CIRC_OUT:
        return circ_out(t, b, c, d)
    else if kind == EASE_CIRC_IN_OUT:
        return circ_in_out(t, b, c, d)
    else if kind == EASE_CUBIC_IN:
        return cubic_in(t, b, c, d)
    else if kind == EASE_CUBIC_OUT:
        return cubic_out(t, b, c, d)
    else if kind == EASE_CUBIC_IN_OUT:
        return cubic_in_out(t, b, c, d)
    else if kind == EASE_QUAD_IN:
        return quad_in(t, b, c, d)
    else if kind == EASE_QUAD_OUT:
        return quad_out(t, b, c, d)
    else if kind == EASE_QUAD_IN_OUT:
        return quad_in_out(t, b, c, d)
    else if kind == EASE_EXPO_IN:
        return expo_in(t, b, c, d)
    else if kind == EASE_EXPO_OUT:
        return expo_out(t, b, c, d)
    else if kind == EASE_EXPO_IN_OUT:
        return expo_in_out(t, b, c, d)
    else if kind == EASE_BACK_IN:
        return back_in(t, b, c, d)
    else if kind == EASE_BACK_OUT:
        return back_out(t, b, c, d)
    else if kind == EASE_BACK_IN_OUT:
        return back_in_out(t, b, c, d)
    else if kind == EASE_BOUNCE_OUT:
        return bounce_out(t, b, c, d)
    else if kind == EASE_BOUNCE_IN:
        return bounce_in(t, b, c, d)
    else if kind == EASE_BOUNCE_IN_OUT:
        return bounce_in_out(t, b, c, d)
    else if kind == EASE_ELASTIC_IN:
        return elastic_in(t, b, c, d)
    else if kind == EASE_ELASTIC_OUT:
        return elastic_out(t, b, c, d)
    else if kind == EASE_ELASTIC_IN_OUT:
        return elastic_in_out(t, b, c, d)

    return no_ease(t, b, c, d)


public function kind_name(kind: int) -> str:
    if kind == EASE_LINEAR_NONE:
        return "EaseLinearNone"
    else if kind == EASE_LINEAR_IN:
        return "EaseLinearIn"
    else if kind == EASE_LINEAR_OUT:
        return "EaseLinearOut"
    else if kind == EASE_LINEAR_IN_OUT:
        return "EaseLinearInOut"
    else if kind == EASE_SINE_IN:
        return "EaseSineIn"
    else if kind == EASE_SINE_OUT:
        return "EaseSineOut"
    else if kind == EASE_SINE_IN_OUT:
        return "EaseSineInOut"
    else if kind == EASE_CIRC_IN:
        return "EaseCircIn"
    else if kind == EASE_CIRC_OUT:
        return "EaseCircOut"
    else if kind == EASE_CIRC_IN_OUT:
        return "EaseCircInOut"
    else if kind == EASE_CUBIC_IN:
        return "EaseCubicIn"
    else if kind == EASE_CUBIC_OUT:
        return "EaseCubicOut"
    else if kind == EASE_CUBIC_IN_OUT:
        return "EaseCubicInOut"
    else if kind == EASE_QUAD_IN:
        return "EaseQuadIn"
    else if kind == EASE_QUAD_OUT:
        return "EaseQuadOut"
    else if kind == EASE_QUAD_IN_OUT:
        return "EaseQuadInOut"
    else if kind == EASE_EXPO_IN:
        return "EaseExpoIn"
    else if kind == EASE_EXPO_OUT:
        return "EaseExpoOut"
    else if kind == EASE_EXPO_IN_OUT:
        return "EaseExpoInOut"
    else if kind == EASE_BACK_IN:
        return "EaseBackIn"
    else if kind == EASE_BACK_OUT:
        return "EaseBackOut"
    else if kind == EASE_BACK_IN_OUT:
        return "EaseBackInOut"
    else if kind == EASE_BOUNCE_OUT:
        return "EaseBounceOut"
    else if kind == EASE_BOUNCE_IN:
        return "EaseBounceIn"
    else if kind == EASE_BOUNCE_IN_OUT:
        return "EaseBounceInOut"
    else if kind == EASE_ELASTIC_IN:
        return "EaseElasticIn"
    else if kind == EASE_ELASTIC_OUT:
        return "EaseElasticOut"
    else if kind == EASE_ELASTIC_IN_OUT:
        return "EaseElasticInOut"

    return "None"
