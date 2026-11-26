# expect-error: interface not found
struct S:
    x: int

function main() -> int:
    var s = S(x = 1)
    let value = adapt[Missing](ref_of(s))
    return 0
