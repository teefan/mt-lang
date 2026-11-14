## Shared text helpers — fixed-arity string joins used across the compiler.
##
## These were previously re-implemented or wrapped in eight modules as
## `j2`..`j6`; one leaf module keeps a single implementation and lets the C
## backend depend on `ir` instead of `lowering`.

import std.string as string


## Join two text parts into one `str`.
public function join_two(a: str, b: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    return buf.as_str()


## Join three text parts into one `str`.
public function join_three(a: str, b: str, c: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    return buf.as_str()


## Join four text parts into one `str`.
public function join_four(a: str, b: str, c: str, d: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    return buf.as_str()


## Join five text parts into one `str`.
public function join_five(a: str, b: str, c: str, d: str, e: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    return buf.as_str()


## Join six text parts into one `str`.
public function join_six(a: str, b: str, c: str, d: str, e: str, f: str) -> str:
    var buf = string.String.create()
    buf.append(a)
    buf.append(b)
    buf.append(c)
    buf.append(d)
    buf.append(e)
    buf.append(f)
    return buf.as_str()
