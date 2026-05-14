#ifndef MT_LANG_MATH_BINDGEN_H
#define MT_LANG_MATH_BINDGEN_H

#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline double mt_math_abs(double value) { return fabs(value); }
static inline double mt_math_sqrt(double value) { return sqrt(value); }
static inline double mt_math_pow(double base, double exponent) { return pow(base, exponent); }
static inline double mt_math_exp(double value) { return exp(value); }
static inline double mt_math_log(double value) { return log(value); }
static inline double mt_math_log10(double value) { return log10(value); }
static inline double mt_math_sin(double radians) { return sin(radians); }
static inline double mt_math_cos(double radians) { return cos(radians); }
static inline double mt_math_tan(double radians) { return tan(radians); }
static inline double mt_math_asin(double value) { return asin(value); }
static inline double mt_math_acos(double value) { return acos(value); }
static inline double mt_math_atan(double value) { return atan(value); }
static inline double mt_math_atan2(double y, double x) { return atan2(y, x); }
static inline double mt_math_floor(double value) { return floor(value); }
static inline double mt_math_ceil(double value) { return ceil(value); }
static inline double mt_math_mod(double value, double divisor) { return fmod(value, divisor); }

#ifdef __cplusplus
}
#endif

#endif
