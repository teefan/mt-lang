extern module std.c.libm:
    link "m"
    include "math.h"

    extern def sqrtf(__x: f32) -> f32

    extern def expf(__x: f32) -> f32

    extern def logf(__x: f32) -> f32

    extern def sinf(__x: f32) -> f32

    extern def cosf(__x: f32) -> f32

    extern def truncf(__x: f32) -> f32

    extern def ceilf(__x: f32) -> f32

    extern def floorf(__x: f32) -> f32

    extern def powf(__x: f32, __y: f32) -> f32

    extern def tanf(__x: f32) -> f32

    extern def atan2f(__y: f32, __x: f32) -> f32

    extern def acosf(__x: f32) -> f32

    extern def fabsf(__x: f32) -> f32
