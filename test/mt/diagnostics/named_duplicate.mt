# expect-error: duplicate named argument 'a' in call to add
function add(a: int, b: int) -> int:
    return a + b

function main() -> int:
    return add(a = 1, a = 2)
