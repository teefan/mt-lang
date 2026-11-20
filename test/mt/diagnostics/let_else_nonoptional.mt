# expect-error: let-else initializer for value must be nullable, Option[T], or Result[T, E], got int
function main() -> int:
    let value = 1 else:
        return 1
    return value
