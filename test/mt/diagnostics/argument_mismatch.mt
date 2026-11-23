# expect-error: argument x to takes expects int, got str
function takes(x: int) -> int:
    return x

function main() -> int:
    return takes("text")
