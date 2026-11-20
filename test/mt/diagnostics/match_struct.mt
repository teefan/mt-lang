# expect-error: match requires an enum, variant, or integer scrutinee, got Point
struct Point:
    x: int

function main() -> int:
    let point = Point(x = 1)
    match point:
        _:
            return 0
