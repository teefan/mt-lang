# POC 025 — Lifetime refs: ref[T] parameters, ref_of, const_ptr_of, ptr_of,
# read (safe and unsafe), implicit borrow.

function increment(val: ref[int]):
    read(val) = read(val) + 1

function read_val(val: ref[int]) -> int:
    return read(val)

function main() -> int:
    var x: int = 0

    # implicit borrow at call site
    increment(ref_of(x))

    let vx = read_val(ref_of(x))
    let _vx = vx

    # ref_of, const_ptr_of, ptr_of
    let r = ref_of(x)
    let _r = r
    let cp = const_ptr_of(x)
    let _cp = cp
    let pp = ptr_of(x)
    let _pp = pp

    # safe read through ref
    let v = read(r)
    let _v = v
    read(r) = 10

    # unsafe read through raw pointer
    var y: int = 5
    let py = ptr_of(y)
    var uv: int
    unsafe:
        uv = read(py)
    let _uv = uv

    return 0
