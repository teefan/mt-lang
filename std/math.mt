module std.math

const pi_f32: f32 = 3.14159274
const tau_f32: f32 = 6.28318548

def min[T](a: T, b: T) -> T:
    if a < b:
        return a
    return b

def max[T](a: T, b: T) -> T:
    if a > b:
        return a
    return b

def abs[T](value: T) -> T:
    let zero = value - value
    if value < zero:
        return -value
    return value

def clamp[T](value: T, min_value: T, max_value: T) -> T:
    if value < min_value:
        return min_value
    elif value > max_value:
        return max_value
    return value

def lerp_f32(start: f32, finish: f32, t: f32) -> f32:
    return start + (finish - start) * t
