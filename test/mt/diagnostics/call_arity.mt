# expect-error: function takes expects 1 arguments, got 2
function takes(x: int) -> int:
    return x

function main() -> int:
    return takes(1, 2)
