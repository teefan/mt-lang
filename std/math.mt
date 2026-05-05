module std.math

pub const pi: float = 3.14159274
pub const tau: float = 6.28318548
pub const deg2rad: float = pi / 180.0
pub const rad2deg: float = 180.0 / pi


pub def min[T](a: T, b: T) -> T:
    if a < b:
        return a
    return b


pub def max[T](a: T, b: T) -> T:
    if a > b:
        return a
    return b


pub def abs[T](value: T) -> T:
    let zero = value - value
    if value < zero:
        return -value
    return value


pub def clamp[T](value: T, min_value: T, max_value: T) -> T:
    if value < min_value:
        return min_value
    elif value > max_value:
        return max_value
    return value


pub def lerp(start: float, finish: float, t: float) -> float:
    return start + (finish - start) * t
