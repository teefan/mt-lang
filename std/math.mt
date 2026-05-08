module std.math

public const pi: float = 3.14159274
public const tau: float = 6.28318548
public const deg2rad: float = pi / 180.0
public const rad2deg: float = 180.0 / pi


public function min[T](a: T, b: T) -> T:
    if a < b:
        return a
    return b


public function max[T](a: T, b: T) -> T:
    if a > b:
        return a
    return b


public function abs[T](value: T) -> T:
    let zero = value - value
    if value < zero:
        return -value
    return value


public function clamp[T](value: T, min_value: T, max_value: T) -> T:
    if value < min_value:
        return min_value
    elif value > max_value:
        return max_value
    return value


public function lerp(start: float, finish: float, t: float) -> float:
    return start + (finish - start) * t
