# expect-error: cannot assign str to int
function main() -> int:
    var count: int = 0
    count = "text"
    return count
