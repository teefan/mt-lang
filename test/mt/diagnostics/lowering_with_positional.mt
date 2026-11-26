# expect-error: lower_with_call: named arguments required
struct P:
    x: int

function main() -> int:
    var p = P(x = 1)
    let q = p.with(2)
    return q.x
