# POC 020 — Compile-time eval: block-bodied const, const function, when,
# inline for, inline if, inline match, type-returning function.

const SQUARED: int = 4 * 4

const COMPUTED -> int:
    return 42

const function twice(x: int) -> int:
    return x * 2

const TEN: int = twice(5)

enum OS:
    linux
    windows

const TARGET: OS = OS.linux

struct Data:
    a: int
    b: float

const VAL: int = 2

function pick_int() -> type:
    return int

function main() -> int:
    let s = SQUARED
    let _s = s
    let c = COMPUTED
    let _c = c
    let t = TEN
    let _t = t

    # when (compile-time conditional)
    when TARGET:
        OS.linux:
            pass
        OS.windows:
            pass

    # inline if
    inline if true:
        pass
    else:
        return 0

    # inline for over compile-time array from reflection
    inline for field in fields_of(Data):
        pass

    # inline match
    inline match VAL:
        1:
            pass
        2:
            pass
        _:
            pass

    return 0
