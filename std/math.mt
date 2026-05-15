import std.c.math as c

public const PI: double = 3.141592653589793
public const HALF_PI: double = 1.5707963267948966
public const QUARTER_PI: double = 0.7853981633974483
public const TAU: double = 6.283185307179586
public const E: double = 2.718281828459045

public foreign function abs(value: double) -> double = c.mt_math_abs
public foreign function sqrt(value: double) -> double = c.mt_math_sqrt
public foreign function pow(base: double, exponent: double) -> double = c.mt_math_pow
public foreign function exp(value: double) -> double = c.mt_math_exp
public foreign function log(value: double) -> double = c.mt_math_log
public foreign function log10(value: double) -> double = c.mt_math_log10
public foreign function sin(radians: double) -> double = c.mt_math_sin
public foreign function cos(radians: double) -> double = c.mt_math_cos
public foreign function tan(radians: double) -> double = c.mt_math_tan
public foreign function asin(value: double) -> double = c.mt_math_asin
public foreign function acos(value: double) -> double = c.mt_math_acos
public foreign function atan(value: double) -> double = c.mt_math_atan
public foreign function atan2(y: double, x: double) -> double = c.mt_math_atan2
public foreign function floor(value: double) -> double = c.mt_math_floor
public foreign function ceil(value: double) -> double = c.mt_math_ceil
public foreign function mod(value: double, divisor: double) -> double = c.mt_math_mod
