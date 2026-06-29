# POC 028 — Nullability flow narrowing
# Tests: After a null check, the type checker must narrow the type from T? to T
# so the variable can be used without unsafe. Tests nullable ptr, cstr.
function nullability_demo() -> int:
    let ptr: ptr[int]? = null
    if ptr == null:
        return 0

    unsafe:
        let val = read(ptr)
        if val == 42:
            return 1

    return 0

function cstr_null_demo() -> int:
    let text: cstr? = c"hello"
    if text != null:
        let ch = text
        let _ch = ch
        return 1
    return 0

function main() -> int:
    var result: int = 0
    result += nullability_demo()
    result += cstr_null_demo()
    return result
