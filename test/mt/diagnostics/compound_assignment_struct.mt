# expect-error: compound assignment is not supported for this type
struct Pair:
    left: int
    right: int

function main() -> int:
    var pair = Pair(left = 1, right = 2)
    pair += Pair(left = 3, right = 4)
    return 0
