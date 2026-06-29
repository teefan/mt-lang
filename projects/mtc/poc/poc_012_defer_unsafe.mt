# POC 012 — Defer and unsafe: defer single stmt and block forms, unsafe block,
# unsafe pointer ops (read, indexing, arithmetic, reinterpret).

function noop():
    pass

function main() -> int:
    var counter: int = 0

    # defer single statement (call expression)
    defer noop()

    # defer block form
    defer:
        noop()

    # unsafe block
    var x: int = 42
    let p = ptr_of(x)
    unsafe:
        read(p) = 99
        let v1 = read(p)
        let _v1 = v1
        let idx = p[0]
        let _idx = idx
        let pa = p + 1
        let _pa = pa

    let _c = counter

    # unsafe read in block expression
    var uv: int
    unsafe:
        uv = read(p)
    let _uv = uv

    # pointer indexing and reinterpret requires unsafe
    var f: float = 3.14f
    let fp = ptr_of(f)
    unsafe:
        let ip = reinterpret[ptr[int]](fp)
        let _ip = ip

    return 0
