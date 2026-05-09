external module examples.language_standard.external_math:
    include "math.h"
    link "m"

    external function cos(value: double) -> double
    external function modf(value: double, integral: ptr[double]) -> double
