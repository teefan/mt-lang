module std.status

pub variant Status[T, E]:
    ok(value: T)
    err(error: E)


pub def is_ok[T, E](value: Status[T, E]) -> bool:
    match value:
        Status.ok:
            return true
        Status.err:
            return false


pub def is_err[T, E](value: Status[T, E]) -> bool:
    return not is_ok(value)


pub def value_or[T, E](value: Status[T, E], fallback: T) -> T:
    match value:
        Status.ok as payload:
            return payload.value
        Status.err:
            return fallback
