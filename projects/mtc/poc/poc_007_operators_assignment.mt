# POC 007 — Local declarations: let/var, guards, operators, assignment
# Tests: let/var with inference and explicit types, compound assignment
# (+= -= *= /= %= &= |= ^= <<= >>=), all binary/unary operators, operator
# continuation, parenthesized wrapping, if-expr.
function main() -> int:
    let x = 10
    var y: int = 20
    var z = 5

    y += 1
    z -= 1
    y *= 2
    y /= 2
    y %= 3
    y &= 7
    y |= 1
    y ^= 3
    y <<= 1
    y >>= 1

    let a = x + y
    let b = x - y
    let c = x / y
    let d = x * y
    let e = x % y
    let f = a & b
    let g = a | b
    let h = a ^ b
    let i = ~a
    let j = a << 2
    let k = a >> 2

    let eq = x == y
    let ne = x != y
    let lt = x < y
    let le = x <= y
    let gt = x > y
    let ge = x >= y
    let and_val = eq and lt
    let or_val = eq or gt
    let not_val = not eq

    let chosen = if x > 5: x else: y

    let wrapped = (x + y - z)
    let continued = x + y - z

    return 0
