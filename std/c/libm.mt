extern module std.c.libm:
    link "m"
    include "libm_helpers.h"

    const M_E: double = 2.7182818284590451
    const M_LOG2E: double = 1.4426950408889634
    const M_LOG10E: double = 0.43429448190325182
    const M_LN2: double = 0.69314718055994531
    const M_LN10: double = 2.3025850929940457
    const M_PI: double = 3.1415926535897931
    const M_PI_2: double = 1.5707963267948966
    const M_PI_4: double = 0.78539816339744828
    const M_1_PI: double = 0.31830988618379069
    const M_2_PI: double = 0.63661977236758138
    const M_2_SQRTPI: double = 1.1283791670955126
    const M_SQRT2: double = 1.4142135623730951
    const M_SQRT1_2: double = 0.70710678118654757
    const M_E_F: float = 2.71828175
    const M_PI_F: float = 3.14159274
    const M_TAU_F: float = 6.28318548

    extern def sqrt(__x: double) -> double
    extern def sqrtf(__x: float) -> float
    extern def exp(__x: double) -> double
    extern def expf(__x: float) -> float
    extern def log(__x: double) -> double
    extern def logf(__x: float) -> float
    extern def sin(__x: double) -> double
    extern def sinf(__x: float) -> float
    extern def cos(__x: double) -> double
    extern def cosf(__x: float) -> float
    extern def trunc(__x: double) -> double
    extern def truncf(__x: float) -> float
    extern def ceil(__x: double) -> double
    extern def ceilf(__x: float) -> float
    extern def floor(__x: double) -> double
    extern def floorf(__x: float) -> float
    extern def pow(__x: double, __y: double) -> double
    extern def powf(__x: float, __y: float) -> float
    extern def tan(__x: double) -> double
    extern def tanf(__x: float) -> float
    extern def atan2(__y: double, __x: double) -> double
    extern def atan2f(__y: float, __x: float) -> float
    extern def acos(__x: double) -> double
    extern def acosf(__x: float) -> float
    extern def fabs(__x: double) -> double
    extern def fabsf(__x: float) -> float
