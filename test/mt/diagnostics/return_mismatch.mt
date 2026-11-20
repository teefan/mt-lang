# expect-error: return type mismatch: expected int, got str
function f() -> int:
    return "text"

function main() -> int:
    return 0
