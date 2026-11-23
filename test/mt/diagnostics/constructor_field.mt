# expect-error: unknown field Point.nope
struct Point:
    x: int

function main() -> int:
    let point = Point(nope = 1)
    return 0
