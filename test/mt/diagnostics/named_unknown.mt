# expect-error: unknown parameter 'c' for add
function add(a: int, b: int) -> int:
    return a + b

function main() -> int:
    return add(a = 1, c = 2)
