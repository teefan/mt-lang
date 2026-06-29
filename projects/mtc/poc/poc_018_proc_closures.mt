# POC 018 — Proc closures: proc expressions, proc captures (scalar, proc
# holding proc), proc as returns, proc in struct fields.

struct Handler:
    cb: proc(x: int) -> int

function make_adder(base: int) -> proc(x: int) -> int:
    return proc(x: int) -> int:
        return x + base

function run_proc(p: proc(x: int) -> int, arg: int) -> int:
    return p(arg)

function main() -> int:
    # proc expression
    let doubler = proc(x: int) -> int:
        return x * 2
    let d = doubler(5)
    let _d = d

    # proc capture (scalar)
    let offset: int = 10
    let adder = proc(x: int) -> int:
        return x + offset
    let a = adder(3)
    let _a = a

    # proc as return value
    let add5 = make_adder(base = 5)
    let r = add5(10)
    let _r = r

    # proc in struct field
    var h = Handler(cb = doubler)
    let hr = h.cb(7)
    let _hr = hr

    # pass proc as argument
    let pr = run_proc(p = doubler, arg = 100)
    let _pr = pr

    # proc holding proc (captured)
    let inner = proc(x: int) -> int:
        return x + 1
    let outer = proc(x: int) -> int:
        return inner(x) + 10
    let o = outer(1)
    let _o = o

    return 0
