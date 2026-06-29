# POC 006 — Functions: params, returns, void, default return, control flow
# Tests: function declarations with typed params, return types, void returning,
# default void return, if/else if/else, while, for (range, array, span),
# break, continue, pass, inline single-statement if.
function add(a: int, b: int) -> int:
    return a + b

function no_op():
    pass

function void_fn() -> void:
    return

function control_flow(n: int) -> int:
    var result: int = 0
    if n > 10:
        result = 1
    else if n > 5:
        result = 2
    else:
        result = 0

    if n == 3: return 3 else: return 0

    var i: int = 0
    while i < n:
        i = i + 1
        result = result + 1
        if i == 2:
            continue
        if i == 5:
            break

    for idx in 0..n:
        result = result + 1

    var arr: array[int, 3]
    arr[0] = 10
    arr[1] = 20
    arr[2] = 30
    for val in arr:
        result = result + val

    let sp = span[int](data = ptr_of(arr[0]), len = 3)
    for val in sp:
        result = result + val

    return result

function main() -> int:
    let a = add(1, 2)
    no_op()
    void_fn()
    let cf = control_flow(3)
    let _cf = cf
    return 0
