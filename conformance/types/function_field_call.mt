# Spec: docs/language-manual.md §3.4 Structs
struct Op:
    apply: fn(value: int) -> int

function twice(x: int) -> int:
    return x * 2

function main() -> int:
    let op = Op(apply = twice)
    if op.apply(3) != 6:
        return 1
    return 0
