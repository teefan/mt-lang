# expect-error: propagation expects Result[T, E] or Option[T], got int
function main() -> int:
    let value = 1?
    return value
