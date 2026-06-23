struct Vec2:
    x: int
    y: int

function main() -> int:
    var v: Vec2 = Vec2(x = 3, y = 4)
    let sum: int = int<-v.x + int<-v.y
    return sum
