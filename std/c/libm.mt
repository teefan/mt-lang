extern module std.c.libm:
    link "m"
    include "math.h"

    extern def sqrtf(__x: float) -> float
    extern def expf(__x: float) -> float
    extern def logf(__x: float) -> float
    extern def sinf(__x: float) -> float
    extern def cosf(__x: float) -> float
    extern def truncf(__x: float) -> float
    extern def ceilf(__x: float) -> float
    extern def floorf(__x: float) -> float
    extern def powf(__x: float, __y: float) -> float
    extern def tanf(__x: float) -> float
    extern def atan2f(__y: float, __x: float) -> float
    extern def acosf(__x: float) -> float
    extern def fabsf(__x: float) -> float
