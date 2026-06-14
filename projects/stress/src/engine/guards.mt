## engine/guards.mt — let/var else: guards, get() recovery

import engine.types as types

# ---------------------------------------------------------------------------
# D1a: let ... else: over nullable pointer
# ---------------------------------------------------------------------------

public function guard_nullable_demo() -> int:
    let ptr: ptr[int]? = null
    let value = ptr else:
        return 0
    unsafe:
        return read(value)

# ---------------------------------------------------------------------------
# D1b: let ... else as error: over built-in Result
# ---------------------------------------------------------------------------

public function guard_else_as_error_demo() -> int:
    let outcome = Result[int, types.EngineError].success(value = 10)
    let result = outcome else as error:
        return int<-(error)
    return result

# ---------------------------------------------------------------------------
# D1c: let _ = expr else: over Result
# ---------------------------------------------------------------------------

public function guard_discard_demo() -> int:
    let _ = Result[int, types.EngineError].success(value = 10) else:
        return -1
    return 1

# ---------------------------------------------------------------------------
# D1d: get(coll, i) recoverable indexing
# ---------------------------------------------------------------------------

public function get_recoverable_demo(index: int) -> int:
    var arr = array[int, 4](10, 20, 30, 40)
    let elem = get(arr, index) else:
        return -1
    unsafe:
        return read(elem)

# ---------------------------------------------------------------------------
# D1e: var ... else: guard over Result
# ---------------------------------------------------------------------------

public function var_else_demo() -> int:
    var mvar = Result[int, types.EngineError].success(value = 5) else as error:
        return int<-(error)
    return mvar
