## std/parse.mt — Numeric string parsing utilities via C FFI
##
## Wraps C's strtol / atof behind a clean str-based API.

import std.libc as c


public function parse_int(text: str, base: int) -> int:
    return int<-(c.parse_long_to_end(text, null, base))


public function parse_float(text: str) -> float:
    return float<-(c.parse_double(text))
