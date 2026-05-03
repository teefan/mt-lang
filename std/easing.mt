module std.easing

import std.c.libm as libm
import std.math as math

pub def none(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return start

pub def linear_none(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change * time / duration + start

pub def linear_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change * time / duration + start

pub def linear_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change * time / duration + start

pub def linear_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change * time / duration + start

pub def sine_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return -change * libm.cosf(time / duration * (math.pi / 2.0)) + change + start

pub def sine_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change * libm.sinf(time / duration * (math.pi / 2.0)) + start

pub def sine_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return -change / 2.0 * (libm.cosf(math.pi * time / duration) - 1.0) + start

pub def circ_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration
    return -change * (libm.sqrtf(1.0 - normalized * normalized) - 1.0) + start

pub def circ_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration - 1.0
    return change * libm.sqrtf(1.0 - normalized * normalized) + start

pub def circ_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return -change / 2.0 * (libm.sqrtf(1.0 - normalized * normalized) - 1.0) + start

    normalized -= 2.0
    return change / 2.0 * (libm.sqrtf(1.0 - normalized * normalized) + 1.0) + start

pub def quad_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration
    return change * normalized * normalized + start

pub def quad_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration
    return -change * normalized * (normalized - 2.0) + start

pub def quad_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * normalized * normalized + start

    return -change / 2.0 * ((normalized - 1.0) * (normalized - 3.0) - 1.0) + start

pub def cubic_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration
    return change * normalized * normalized * normalized + start

pub def cubic_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let normalized = time / duration - 1.0
    return change * (normalized * normalized * normalized + 1.0) + start

pub def cubic_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * normalized * normalized * normalized + start

    normalized -= 2.0
    return change / 2.0 * (normalized * normalized * normalized + 2.0) + start

pub def expo_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == 0.0:
        return start

    return change * libm.powf(2.0, 10.0 * (time / duration - 1.0)) + start

pub def expo_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == duration:
        return start + change

    return change * (-libm.powf(2.0, -10.0 * time / duration) + 1.0) + start

pub def expo_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == 0.0:
        return start
    if time == duration:
        return start + change

    let normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * libm.powf(2.0, 10.0 * (normalized - 1.0)) + start

    return change / 2.0 * (-libm.powf(2.0, -10.0 * (normalized - 1.0)) + 2.0) + start

pub def back_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let overshoot: f32 = 1.70158
    let normalized = time / duration
    return change * normalized * normalized * ((overshoot + 1.0) * normalized - overshoot) + start

pub def back_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let overshoot: f32 = 1.70158
    let normalized = time / duration - 1.0
    return change * (normalized * normalized * ((overshoot + 1.0) * normalized + overshoot) + 1.0) + start

pub def back_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    let scaled_overshoot: f32 = 1.70158 * 1.525
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized - scaled_overshoot)) + start

    normalized -= 2.0
    return change / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized + scaled_overshoot) + 2.0) + start

pub def bounce_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    var normalized = time / duration

    if normalized < 1.0 / 2.75:
        return change * (7.5625 * normalized * normalized) + start
    elif normalized < 2.0 / 2.75:
        normalized -= 1.5 / 2.75
        return change * (7.5625 * normalized * normalized + 0.75) + start
    elif normalized < 2.5 / 2.75:
        normalized -= 2.25 / 2.75
        return change * (7.5625 * normalized * normalized + 0.9375) + start

    normalized -= 2.625 / 2.75
    return change * (7.5625 * normalized * normalized + 0.984375) + start

pub def bounce_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    return change - bounce_out(duration - time, 0.0, change, duration) + start

pub def bounce_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time < duration / 2.0:
        return bounce_in(time * 2.0, 0.0, change, duration) * 0.5 + start

    return bounce_out(time * 2.0 - duration, 0.0, change, duration) * 0.5 + change * 0.5 + start

pub def elastic_in(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == 0.0:
        return start

    var normalized = time / duration
    if normalized == 1.0:
        return start + change

    let period = duration * 0.3
    let amplitude = change
    let shift = period / 4.0
    normalized -= 1.0

    let post_fix = amplitude * libm.powf(2.0, 10.0 * normalized)
    return -(post_fix * libm.sinf((normalized * duration - shift) * math.tau / period)) + start

pub def elastic_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == 0.0:
        return start

    let normalized = time / duration
    if normalized == 1.0:
        return start + change

    let period = duration * 0.3
    let amplitude = change
    let shift = period / 4.0

    return amplitude * libm.powf(2.0, -10.0 * normalized) * libm.sinf((normalized * duration - shift) * math.tau / period) + change + start

pub def elastic_in_out(time: f32, start: f32, change: f32, duration: f32) -> f32:
    if time == 0.0:
        return start

    var normalized = time / (duration / 2.0)
    if normalized == 2.0:
        return start + change

    let period = duration * (0.3 * 1.5)
    let amplitude = change
    let shift = period / 4.0

    if normalized < 1.0:
        normalized -= 1.0
        let post_fix = amplitude * libm.powf(2.0, 10.0 * normalized)
        return -0.5 * (post_fix * libm.sinf((normalized * duration - shift) * math.tau / period)) + start

    normalized -= 1.0
    let post_fix = amplitude * libm.powf(2.0, -10.0 * normalized)
    return post_fix * libm.sinf((normalized * duration - shift) * math.tau / period) * 0.5 + change + start