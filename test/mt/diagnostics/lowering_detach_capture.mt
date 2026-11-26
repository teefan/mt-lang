# expect-error: detach with captured variables is not yet supported
function work(x: int) -> int:
    return x

function main() -> int:
    let x = 1
    let handle = detach work(x)
    gather handle
    return 0
