# POC 026 — Builtins: zero[T], default[T], size_of, align_of, offset_of,
# get(arr, idx), reinterpret[T], ref_of, const_ptr_of, ptr_of, read,
# hash[T], equal[T], order[T], cast (T<-expr).

import std.hash

struct Vec2:
    x: float
    y: float

extending Vec2:
    static function default() -> Vec2:
        return Vec2(x = 0.0, y = 0.0)

function main() -> int:
    # zero[T]
    let zv = zero[Vec2]
    let _zv = zv
    let zi = zero[int]
    let _zi = zi

    # default[T]
    let dv = default[Vec2]
    let _dv = dv

    # size_of, align_of, offset_of
    let sz = size_of(Vec2)
    let al = align_of(Vec2)
    let off = offset_of(Vec2, y)
    let _sz = sz
    let _al = al
    let _off = off

    # get(arr, idx)
    var arr: array[int, 3]
    arr[0] = 10
    arr[1] = 20
    arr[2] = 30
    let g = get(arr, 1)
    let _g = g

    # ptr_of, const_ptr_of, ref_of
    var v: int = 42
    let p = ptr_of(v)
    let cp = const_ptr_of(v)
    let r = ref_of(v)
    let _p = p
    let _cp = cp
    let _r = r

    # safe read through ref
    let rv = read(r)
    let _rv = rv

    # unsafe read through ptr
    var uv: int
    unsafe:
        uv = read(p)
    let _upv = uv

    # reinterpret (unsafe)
    var f: float = 1.0f
    let fp = ptr_of(f)
    unsafe:
        let ip = reinterpret[ptr[int]](fp)
        let _ip = ip

    # hash, equal, order
    var av: int = 10
    var bv: int = 20
    let h = hash[int](av)
    let _h = h
    let eq = equal[int](av, bv)
    let _eq = eq
    let ord = order[int](const_ptr_of(av), const_ptr_of(bv))
    let _ord = ord

    # cast
    let fv: float = 3.14f
    let iv = int<-fv
    let _iv = iv

    return 0
