# POC 023 — Struct features: nested structs, @[packed], struct.with()
# partial update, named arguments, tuple, struct destructuring.

@[packed]
struct Header:
    tag: ubyte
    len: ushort

struct Vec2:
    x: float
    y: float

struct Outer:
    val: int

    struct Inner:
        a: int
        b: float

    nested: Inner

function make_vec(x: float, y: float) -> Vec2:
    return Vec2(x = x, y = y)

function main() -> int:
    # nested struct
    var o: Outer
    o.val = 10
    o.nested.a = 5
    o.nested.b = 3.14f
    let ni: Outer.Inner = Outer.Inner(a = 1, b = 2.0)
    let _ni = ni

    # @[packed] struct
    var h: Header
    h.tag = 0ub
    h.len = 0us
    let _h = h

    # struct.with() partial update
    let v = Vec2(x = 1.0, y = 2.0)
    let v2 = v.with(x = 5.0)
    let _v2 = v2

    # named arguments
    let nv = make_vec(x = 3.0, y = 4.0)
    let _nv = nv

    # tuple positional
    let tup = (1, "hi")
    let (a, b) = tup
    let _a = a
    let _b = b

    # tuple named
    let ntup = (num = 42, msg = "hello")
    let (num, msg) = ntup
    let _num = num
    let _msg = msg

    # struct destructuring
    let Vec2(x, y) = v
    let _sx = x
    let _sy = y

    return 0
