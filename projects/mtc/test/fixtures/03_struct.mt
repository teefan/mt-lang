struct Vec2:
    x: int
    y: int

function main() -> int:
    var v: Vec2 = Vec2(x = 10, y = 20)
    return v.x + v.y
