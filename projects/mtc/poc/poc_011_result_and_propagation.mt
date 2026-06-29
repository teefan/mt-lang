# POC 011 — Result and propagation: Result[T,E] construction, match, let-else,
# else as error, ? propagation, let _ = ... else:, var ... else:.

function make_result(ok: bool) -> Result[int, str]:
    if ok:
        return Result[int, str].success(value = 42)

    return Result[int, str].failure(error = "fail")

function propagate(ok: bool) -> Result[int, str]:
    let val = make_result(ok)?
    return Result[int, str].success(value = val + 1)

function main() -> int:
    # Result construction and match
    let r = make_result(true)
    match r:
        Result[int, str].success(value):
            let _v = value
        Result[int, str].failure(error):
            let _e = error

    # let-else
    let g = make_result(true) else:
        return 1
    let _g = g

    # let-else as error
    let g2 = make_result(true) else as err:
        let _e = err
        return 1
    let _g2 = g2

    # var ... else:
    let mv = make_result(true) else:
        return 1
    let _m = mv

    # let _ = ... else: discard
    let _ = make_result(true) else:
        return 1

    # unwrap / expect / unwrap_error / unwrap_or
    let v = r.unwrap()
    let ev = r.expect("must be success")
    let ov = r.unwrap_or(99)

    let err_r = make_result(false)
    let ue = err_r.unwrap_error()

    let _v = v
    let _ev = ev
    let _ov = ov
    let _ue = ue

    return 0
