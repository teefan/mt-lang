# POC 005 — Struct, union, enum, flags, opaque, type alias
# Tests: struct declaration with fields, union, enum (with and without explicit
# backing type, auto-increment, explicit values), flags (with shift expressions),
# opaque, type alias.
type Seconds = float

struct Vec2:
    x: float
    y: float

union Number:
    i: int
    f: float

enum State: ubyte
    idle    = 0
    running = 1

enum Color:
    red
    green
    blue

flags Mask: uint
    a = 1 << 0
    b = 1 << 1

opaque RawHandle

function main() -> int:
    var v = Vec2(x = 1.0, y = 2.0)
    var u: Number
    u.i = 42
    let s = State.running
    let c = Color.red
    let m = Mask.a | Mask.b
    let _v = v
    let _s = s
    let _c = c
    let _m = m
    return 0
