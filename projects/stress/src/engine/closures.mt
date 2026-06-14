## engine/closures.mt — comprehensive proc/closure stress testing

import engine.types as types

# ---------------------------------------------------------------------------
# 1. Basic captures: scalars, arrays
# ---------------------------------------------------------------------------

public function scalar_capture_demo() -> int:
    let offset = 10
    let multiply = proc(x: int) -> int:
        return x * offset
    return multiply(5)

public function array_capture_demo() -> int:
    let weights = array[int, 4](1, 2, 3, 4)
    let sum_weights = proc() -> int:
        var total: int = 0
        var i: int = 0
        while i < 4:
            total += weights[i]
            i += 1
        return total
    return sum_weights()

# ---------------------------------------------------------------------------
# 2. Multiple captures of different types
# ---------------------------------------------------------------------------

public function multi_capture_demo() -> bool:
    let int_val = 42
    let double_val: double = 3.14
    let flag = true
    let label: str = "mixed"
    let cb = proc() -> bool:
        var s = flag and (int_val > 0) and (double_val > 0.0)
        var _label = label
        return s
    return cb()

# ---------------------------------------------------------------------------
# 3. Proc capturing another proc
# ---------------------------------------------------------------------------

public function proc_capture_proc_demo() -> int:
    let base = proc(x: int) -> int:
        return x + 1
    let composite = proc(x: int) -> int:
        return base(x) * 2
    return composite(5)

# ---------------------------------------------------------------------------
# 4. Proc capturing proc which captures proc (2 levels deep)
# ---------------------------------------------------------------------------

public function proc_capture_deep_demo() -> int:
    let leaf = proc(x: int) -> int:
        return x + 1
    let middle = proc(x: int) -> int:
        return leaf(x) * 2
    let root = proc(x: int) -> int:
        return middle(x) + 3
    return root(5)

# ---------------------------------------------------------------------------
# 5. Proc returning proc (higher-order factory)
# ---------------------------------------------------------------------------

public function make_scaler(factor: double) -> proc(value: double) -> double:
    return proc(value: double) -> double:
        return value * factor

public function make_curried_adder(a: int) -> proc(b: int) -> int:
    return proc(b: int) -> int:
        return a + b

# ---------------------------------------------------------------------------
# 6. Proc capturing both scalar and another proc
# ---------------------------------------------------------------------------

public function mixed_capture_demo() -> int:
    let multiplier = 3
    let inner = proc(x: int) -> int:
        return x * 2
    let combined = proc(x: int) -> int:
        return inner(x) * multiplier
    return combined(4)

# ---------------------------------------------------------------------------
# 7. Proc stored in struct fields
# ---------------------------------------------------------------------------

struct ProcHolder:
    transform: proc(value: int) -> int
    predicate: proc(item: int) -> bool
    cleanup: proc() -> void

public function proc_struct_demo() -> int:
    let factor = 10
    let t = proc(value: int) -> int:
        return value * factor
    let p = proc(item: int) -> bool:
        return item > factor
    let c = proc() -> void:
        pass
    var holder = ProcHolder(transform = t, predicate = p, cleanup = c)
    if holder.predicate(15):
        return holder.transform(3)
    return 0

# ---------------------------------------------------------------------------
# 8. Proc stored in array
# ---------------------------------------------------------------------------

public function proc_array_demo(selector: int) -> int:
    let offset = 100
    var ops: array[types.Callback, 3]
    ops[0] = proc(value: int) -> int:
        return value + offset
    ops[1] = proc(value: int) -> int:
        return value * 2 + offset
    ops[2] = proc(value: int) -> int:
        return value - offset
    if selector >= 0 and selector < 3:
        return ops[selector](10)
    return 0

# ---------------------------------------------------------------------------
# 9. Proc returning from function, used in array
# ---------------------------------------------------------------------------

public function build_processor(base: int, mode: int) -> types.Callback:
    if mode == 0:
        return proc(value: int) -> int:
            return value + base
    return proc(value: int) -> int:
        return value * base

public function proc_array_from_factory_demo() -> int:
    var processors: array[types.Callback, 2]
    processors[0] = build_processor(5, 0)
    processors[1] = build_processor(2, 1)
    return processors[0](10) + processors[1](10)

# ---------------------------------------------------------------------------
# 10. Event listener style: subscribe with proc callbacks
# ---------------------------------------------------------------------------

public function listener_demo(threshold: int) -> bool:
    let border = threshold
    let check = proc(value: int) -> bool:
        return value > border
    return check(50)

# ---------------------------------------------------------------------------
# 11. Proc in variant payload field
# ---------------------------------------------------------------------------

variant CallbackVariant:
    simple(cb: proc() -> int)
    mapped(cb: proc(x: int) -> int, factor: int)
    none

public function variant_proc_demo(which: int) -> int:
    let base = 10
    let simple_cb = proc() -> int:
        return base + 1
    let mapped_cb = proc(x: int) -> int:
        return x * base

    var v: CallbackVariant
    if which == 0:
        v = CallbackVariant.simple(cb = simple_cb)
    else if which == 1:
        v = CallbackVariant.mapped(cb = mapped_cb, factor = 3)
    else:
        v = CallbackVariant.none

    match v:
        CallbackVariant.simple as s:
            return s.cb()
        CallbackVariant.mapped as m:
            return m.cb(m.factor)
        CallbackVariant.none:
            return 0

# ---------------------------------------------------------------------------
# 12. Direct function-to-proc coercion
# ---------------------------------------------------------------------------

public function identity_int(x: int) -> int:
    return x

public function apply_transform(t: proc(x: int) -> int, value: int) -> int:
    return t(value)

public function function_to_proc_coercion_demo() -> int:
    return apply_transform(identity_int, 42)

# ---------------------------------------------------------------------------
# 13. Void-returning proc with captures
# ---------------------------------------------------------------------------

public function void_proc_demo(base: int) -> int:
    var counter: int = 0
    let tick = proc() -> void:
        return
    tick()
    tick()
    counter += base
    return counter

# ---------------------------------------------------------------------------
# 14. Proc inside match expression
# ---------------------------------------------------------------------------

public function proc_in_match_demo(kind: int) -> int:
    let factor = 2
    match kind:
        0:
            var cb = proc(x: int) -> int:
                return x * factor
            return cb(5)
        1:
            return 0
        _:
            return -1
