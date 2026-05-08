module std.easing

import std.libm as libm
import std.math as math


public function none(time: float, start: float, change: float, duration: float) -> float:
    return start


public function linear_none(time: float, start: float, change: float, duration: float) -> float:
    return change * time / duration + start


public function linear_in(time: float, start: float, change: float, duration: float) -> float:
    return change * time / duration + start


public function linear_out(time: float, start: float, change: float, duration: float) -> float:
    return change * time / duration + start


public function linear_in_out(time: float, start: float, change: float, duration: float) -> float:
    return change * time / duration + start


public function sine_in(time: float, start: float, change: float, duration: float) -> float:
    return -change * libm.cosf(time / duration * (math.pi / 2.0)) + change + start


public function sine_out(time: float, start: float, change: float, duration: float) -> float:
    return change * libm.sinf(time / duration * (math.pi / 2.0)) + start


public function sine_in_out(time: float, start: float, change: float, duration: float) -> float:
    return -change / 2.0 * (libm.cosf(math.pi * time / duration) - 1.0) + start


public function circ_in(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration
    return -change * (libm.sqrtf(1.0 - normalized * normalized) - 1.0) + start


public function circ_out(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration - 1.0
    return change * libm.sqrtf(1.0 - normalized * normalized) + start


public function circ_in_out(time: float, start: float, change: float, duration: float) -> float:
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return -change / 2.0 * (libm.sqrtf(1.0 - normalized * normalized) - 1.0) + start

    normalized -= 2.0
    return change / 2.0 * (libm.sqrtf(1.0 - normalized * normalized) + 1.0) + start


public function quad_in(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration
    return change * normalized * normalized + start


public function quad_out(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration
    return -change * normalized * (normalized - 2.0) + start


public function quad_in_out(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * normalized * normalized + start

    return -change / 2.0 * ((normalized - 1.0) * (normalized - 3.0) - 1.0) + start


public function cubic_in(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration
    return change * normalized * normalized * normalized + start


public function cubic_out(time: float, start: float, change: float, duration: float) -> float:
    let normalized = time / duration - 1.0
    return change * (normalized * normalized * normalized + 1.0) + start


public function cubic_in_out(time: float, start: float, change: float, duration: float) -> float:
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * normalized * normalized * normalized + start

    normalized -= 2.0
    return change / 2.0 * (normalized * normalized * normalized + 2.0) + start


public function expo_in(time: float, start: float, change: float, duration: float) -> float:
    if time == 0.0:
        return start

    return change * libm.powf(2.0, 10.0 * (time / duration - 1.0)) + start


public function expo_out(time: float, start: float, change: float, duration: float) -> float:
    if time == duration:
        return start + change

    return change * (-libm.powf(2.0, -10.0 * time / duration) + 1.0) + start


public function expo_in_out(time: float, start: float, change: float, duration: float) -> float:
    if time == 0.0:
        return start
    if time == duration:
        return start + change

    let normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * libm.powf(2.0, 10.0 * (normalized - 1.0)) + start

    return change / 2.0 * (-libm.powf(2.0, -10.0 * (normalized - 1.0)) + 2.0) + start


public function back_in(time: float, start: float, change: float, duration: float) -> float:
    let overshoot: float = 1.70158
    let normalized = time / duration
    return change * normalized * normalized * ((overshoot + 1.0) * normalized - overshoot) + start


public function back_out(time: float, start: float, change: float, duration: float) -> float:
    let overshoot: float = 1.70158
    let normalized = time / duration - 1.0
    return change * (normalized * normalized * ((overshoot + 1.0) * normalized + overshoot) + 1.0) + start


public function back_in_out(time: float, start: float, change: float, duration: float) -> float:
    let scaled_overshoot: float = 1.70158 * 1.525
    var normalized = time / (duration / 2.0)
    if normalized < 1.0:
        return change / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized - scaled_overshoot)) + start

    normalized -= 2.0
    return change / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized + scaled_overshoot) + 2.0) + start


public function bounce_out(time: float, start: float, change: float, duration: float) -> float:
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


public function bounce_in(time: float, start: float, change: float, duration: float) -> float:
    return change - bounce_out(duration - time, 0.0, change, duration) + start


public function bounce_in_out(time: float, start: float, change: float, duration: float) -> float:
    if time < duration / 2.0:
        return bounce_in(time * 2.0, 0.0, change, duration) * 0.5 + start

    return bounce_out(time * 2.0 - duration, 0.0, change, duration) * 0.5 + change * 0.5 + start


public function elastic_in(time: float, start: float, change: float, duration: float) -> float:
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


public function elastic_out(time: float, start: float, change: float, duration: float) -> float:
    if time == 0.0:
        return start

    let normalized = time / duration
    if normalized == 1.0:
        return start + change

    let period = duration * 0.3
    let amplitude = change
    let shift = period / 4.0

    return amplitude * libm.powf(2.0, -10.0 * normalized) * libm.sinf((normalized * duration - shift) * math.tau / period) + change + start


public function elastic_in_out(time: float, start: float, change: float, duration: float) -> float:
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
