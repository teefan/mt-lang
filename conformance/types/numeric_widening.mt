# Spec: README.md §13 Safety And Conversion Rules

function take(f: float) -> float:
    return f

function main() -> int:
    let n: int = 7
    if take(n) != 7.0:
        return 1
    return 0
