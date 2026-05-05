#ifndef MT_LIBM_HELPERS_H
#define MT_LIBM_HELPERS_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef _USE_MATH_DEFINES
#define _USE_MATH_DEFINES
#endif

#include <math.h>

#ifndef M_E
#define M_E 2.71828182845904523536
#endif

#ifndef M_LOG2E
#define M_LOG2E 1.44269504088896340736
#endif

#ifndef M_LOG10E
#define M_LOG10E 0.43429448190325182765
#endif

#ifndef M_LN2
#define M_LN2 0.69314718055994530942
#endif

#ifndef M_LN10
#define M_LN10 2.30258509299404568402
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifndef M_PI_2
#define M_PI_2 1.57079632679489661923
#endif

#ifndef M_PI_4
#define M_PI_4 0.78539816339744830962
#endif

#ifndef M_1_PI
#define M_1_PI 0.31830988618379067154
#endif

#ifndef M_2_PI
#define M_2_PI 0.63661977236758134308
#endif

#ifndef M_2_SQRTPI
#define M_2_SQRTPI 1.12837916709551257390
#endif

#ifndef M_SQRT2
#define M_SQRT2 1.41421356237309504880
#endif

#ifndef M_SQRT1_2
#define M_SQRT1_2 0.70710678118654752440
#endif

#ifndef M_E_F
#define M_E_F ((float) M_E)
#endif

#ifndef M_PI_F
#define M_PI_F ((float) M_PI)
#endif

#ifndef M_TAU_F
#define M_TAU_F ((float) (2.0 * M_PI))
#endif

#endif
