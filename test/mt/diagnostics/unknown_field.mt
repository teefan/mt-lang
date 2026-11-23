# expect-error: unknown field Point.y
struct Point:
    x: int

function main() -> int:
    let point = Point(x = 1)
    return point.y
