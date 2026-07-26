## Tweening and easing — smooth value interpolation.
##
## Normalized easing functions map [0,1] linear progress to
## eased progress, following the Robert Penner convention.
## A Tween struct tracks elapsed time and computes the
## current interpolated value.
##
##   import std.tween as tw
##   var t = tw.Tween.create(0.0, 100.0, 2.0, tw.Easing.ease_out_cubic)
##   while t.active:
##       let v = t.value()
##       apply_position(v)
##       t.step(dt)

import std.math as math


public enum Easing: ubyte
    linear = 0
    ease_in_quad = 1
    ease_out_quad = 2
    ease_in_out_quad = 3
    ease_in_cubic = 4
    ease_out_cubic = 5
    ease_in_out_cubic = 6
    ease_in_quart = 7
    ease_out_quart = 8
    ease_in_out_quart = 9
    ease_in_quint = 10
    ease_out_quint = 11
    ease_in_out_quint = 12
    ease_in_sine = 13
    ease_out_sine = 14
    ease_in_out_sine = 15
    ease_in_expo = 17
    ease_out_expo = 18
    ease_in_out_expo = 19
    ease_in_circ = 20
    ease_out_circ = 21
    ease_in_out_circ = 22
    ease_in_back = 23
    ease_out_back = 24
    ease_in_out_back = 25
    ease_in_elastic = 26
    ease_out_elastic = 27
    ease_in_out_elastic = 28
    ease_in_bounce = 29
    ease_out_bounce = 30
    ease_in_out_bounce = 31


public struct Tween:
    duration: float
    elapsed: float
    from: float
    to: float
    easing: Easing
    active: bool


# ── math helpers ──

function pow_f(base: float, exp: float) -> float:
    return float<-(math.pow(double<-(base), double<-(exp)))


function sin_f(x: float) -> float:
    return float<-(math.sin(double<-(x)))


function cos_f(x: float) -> float:
    return float<-(math.cos(double<-(x)))


function sqrt_f(x: float) -> float:
    return float<-(math.sqrt(double<-(x)))


function ease_out_bounce_f(t: float) -> float:
    let n1 = 7.5625
    let d1 = 2.75
    if t < 1.0 / d1:
        return n1 * t * t
    if t < 2.0 / d1:
        let t1 = t - 1.5 / d1
        return n1 * t1 * t1 + 0.75
    if t < 2.5 / d1:
        let t1 = t - 2.25 / d1
        return n1 * t1 * t1 + 0.9375
    let t1 = t - 2.625 / d1
    return n1 * t1 * t1 + 0.984375


# ── tween ──

extending Tween:
    public static function apply_easing(easing: Easing, t: float) -> float:
        if easing == Easing.linear:
            return t

        if easing == Easing.ease_in_quad:
            return t * t
        if easing == Easing.ease_out_quad:
            return t * (2.0 - t)
        if easing == Easing.ease_in_out_quad:
            if t < 0.5:
                return 2.0 * t * t
            return -1.0 + (4.0 - 2.0 * t) * t

        if easing == Easing.ease_in_cubic:
            return t * t * t
        if easing == Easing.ease_out_cubic:
            let t1 = t - 1.0
            return t1 * t1 * t1 + 1.0
        if easing == Easing.ease_in_out_cubic:
            if t < 0.5:
                return 4.0 * t * t * t
            let t1 = -2.0 * t + 2.0
            return 1.0 - t1 * t1 * t1 / 2.0

        if easing == Easing.ease_in_quart:
            return t * t * t * t
        if easing == Easing.ease_out_quart:
            let t1 = t - 1.0
            return 1.0 - t1 * t1 * t1 * t1
        if easing == Easing.ease_in_out_quart:
            if t < 0.5:
                return 8.0 * t * t * t * t
            let t1 = t - 1.0
            return 1.0 - 8.0 * t1 * t1 * t1 * t1

        if easing == Easing.ease_in_quint:
            return t * t * t * t * t
        if easing == Easing.ease_out_quint:
            let t1 = t - 1.0
            return 1.0 + t1 * t1 * t1 * t1 * t1
        if easing == Easing.ease_in_out_quint:
            if t < 0.5:
                return 16.0 * t * t * t * t * t
            let t1 = -2.0 * t + 2.0
            return 1.0 - t1 * t1 * t1 * t1 * t1 / 2.0

        if easing == Easing.ease_in_sine:
            return 1.0 - cos_f(t * 1.5707963)
        if easing == Easing.ease_out_sine:
            return sin_f(t * 1.5707963)
        if easing == Easing.ease_in_out_sine:
            return -(cos_f(3.14159265 * t) - 1.0) / 2.0

        if easing == Easing.ease_in_expo:
            if t <= 0.0: return 0.0
            return pow_f(2.0, 10.0 * (t - 1.0))
        if easing == Easing.ease_out_expo:
            if t >= 1.0: return 1.0
            return 1.0 - pow_f(2.0, -10.0 * t)
        if easing == Easing.ease_in_out_expo:
            if t <= 0.0: return 0.0
            if t >= 1.0: return 1.0
            if t < 0.5:
                return pow_f(2.0, 20.0 * t - 10.0) / 2.0
            return (2.0 - pow_f(2.0, -20.0 * t + 10.0)) / 2.0

        if easing == Easing.ease_in_circ:
            return 1.0 - sqrt_f(1.0 - t * t)
        if easing == Easing.ease_out_circ:
            return sqrt_f(1.0 - (t - 1.0) * (t - 1.0))
        if easing == Easing.ease_in_out_circ:
            if t < 0.5:
                return (1.0 - sqrt_f(1.0 - 4.0 * t * t)) / 2.0
            return (sqrt_f(1.0 - (-2.0 * t + 2.0) * (-2.0 * t + 2.0)) + 1.0) / 2.0

        if easing == Easing.ease_in_back:
            let c1 = 1.70158
            return (c1 + 1.0) * t * t * t - c1 * t * t
        if easing == Easing.ease_out_back:
            let c1 = 1.70158
            let t1 = t - 1.0
            return 1.0 + (c1 + 1.0) * t1 * t1 * t1 + c1 * t1 * t1
        if easing == Easing.ease_in_out_back:
            let c1 = 1.70158
            let c2 = c1 * 1.525
            if t < 0.5:
                return (4.0 * t * t * ((c2 + 1.0) * 2.0 * t - c2)) / 2.0
            let t1 = t - 1.0
            return (4.0 * t1 * t1 * ((c2 + 1.0) * 2.0 * t1 + c2) + 2.0) / 2.0

        if easing == Easing.ease_in_elastic:
            if t <= 0.0: return 0.0
            if t >= 1.0: return 1.0
            return -pow_f(2.0, 10.0 * t - 10.0) * sin_f((t * 10.0 - 10.75) * 2.0943951)
        if easing == Easing.ease_out_elastic:
            if t <= 0.0: return 0.0
            if t >= 1.0: return 1.0
            return pow_f(2.0, -10.0 * t) * sin_f((t * 10.0 - 0.75) * 2.0943951) + 1.0
        if easing == Easing.ease_in_out_elastic:
            if t <= 0.0: return 0.0
            if t >= 1.0: return 1.0
            if t < 0.5:
                return -(pow_f(2.0, 20.0 * t - 10.0) * sin_f((20.0 * t - 11.125) * 1.3962634)) / 2.0
            return (pow_f(2.0, -20.0 * t + 10.0) * sin_f((20.0 * t - 11.125) * 1.3962634)) / 2.0 + 1.0

        if easing == Easing.ease_in_bounce:
            return 1.0 - ease_out_bounce_f(1.0 - t)
        if easing == Easing.ease_out_bounce:
            return ease_out_bounce_f(t)
        if easing == Easing.ease_in_out_bounce:
            if t < 0.5:
                return (1.0 - ease_out_bounce_f(1.0 - 2.0 * t)) / 2.0
            return (1.0 + ease_out_bounce_f(2.0 * t - 1.0)) / 2.0

        return t


    public static function create(from: float, to: float, duration: float, easing: Easing) -> Tween:
        return Tween(
            duration = duration,
            elapsed = 0.0,
            from = from,
            to = to,
            easing = easing,
            active = true
        )


    public function value() -> float:
        if this.duration <= 0.0:
            return this.to
        let progress = this.elapsed / this.duration
        if progress >= 1.0:
            return this.to
        if progress <= 0.0:
            return this.from
        let eased = Tween.apply_easing(this.easing, progress)
        return this.from + (this.to - this.from) * eased


    public editable function step(dt: float) -> bool:
        if not this.active:
            return false
        this.elapsed = this.elapsed + dt
        if this.elapsed >= this.duration:
            this.elapsed = this.duration
            this.active = false
            return true
        return false


    public editable function reset(from: float, to: float, duration: float, easing: Easing) -> void:
        this.from = from
        this.to = to
        this.duration = duration
        this.easing = easing
        this.elapsed = 0.0
        this.active = true


    public editable function stop() -> void:
        this.active = false


# ── multi-type tweens ──

public struct Tween2:
    x: Tween
    y: Tween


public struct Tween3:
    x: Tween
    y: Tween
    z: Tween


public struct Tween4:
    x: Tween
    y: Tween
    z: Tween
    w: Tween


extending Tween2:
    public static function create(from: vec2, to: vec2, duration: float, easing: Easing) -> Tween2:
        return Tween2(
            x = Tween.create(from.x, to.x, duration, easing),
            y = Tween.create(from.y, to.y, duration, easing)
        )


    public function value() -> vec2:
        return vec2(x = this.x.value(), y = this.y.value())


    public editable function step(dt: float) -> bool:
        let done_x = this.x.step(dt)
        let done_y = this.y.step(dt)
        return done_x or done_y


    public editable function reset(from: vec2, to: vec2, duration: float, easing: Easing) -> void:
        this.x.reset(from.x, to.x, duration, easing)
        this.y.reset(from.y, to.y, duration, easing)


    public editable function stop() -> void:
        this.x.stop()
        this.y.stop()


extending Tween3:
    public static function create(from: vec3, to: vec3, duration: float, easing: Easing) -> Tween3:
        return Tween3(
            x = Tween.create(from.x, to.x, duration, easing),
            y = Tween.create(from.y, to.y, duration, easing),
            z = Tween.create(from.z, to.z, duration, easing)
        )


    public function value() -> vec3:
        return vec3(x = this.x.value(), y = this.y.value(), z = this.z.value())


    public editable function step(dt: float) -> bool:
        let dx = this.x.step(dt)
        let dy = this.y.step(dt)
        let dz = this.z.step(dt)
        return dx or dy or dz


    public editable function reset(from: vec3, to: vec3, duration: float, easing: Easing) -> void:
        this.x.reset(from.x, to.x, duration, easing)
        this.y.reset(from.y, to.y, duration, easing)
        this.z.reset(from.z, to.z, duration, easing)


    public editable function stop() -> void:
        this.x.stop()
        this.y.stop()
        this.z.stop()


extending Tween4:
    public static function create(from: vec4, to: vec4, duration: float, easing: Easing) -> Tween4:
        return Tween4(
            x = Tween.create(from.x, to.x, duration, easing),
            y = Tween.create(from.y, to.y, duration, easing),
            z = Tween.create(from.z, to.z, duration, easing),
            w = Tween.create(from.w, to.w, duration, easing)
        )


    public function value() -> vec4:
        return vec4(x = this.x.value(), y = this.y.value(), z = this.z.value(), w = this.w.value())


    public editable function step(dt: float) -> bool:
        let dx = this.x.step(dt)
        let dy = this.y.step(dt)
        let dz = this.z.step(dt)
        let dw = this.w.step(dt)
        return dx or dy or dz or dw


    public editable function reset(from: vec4, to: vec4, duration: float, easing: Easing) -> void:
        this.x.reset(from.x, to.x, duration, easing)
        this.y.reset(from.y, to.y, duration, easing)
        this.z.reset(from.z, to.z, duration, easing)
        this.w.reset(from.w, to.w, duration, easing)


    public editable function stop() -> void:
        this.x.stop()
        this.y.stop()
        this.z.stop()
        this.w.stop()