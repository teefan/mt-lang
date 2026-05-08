module std.maybe

pub variant Maybe[T]:
    some(value: T)
    none


pub def is_some[T](value: Maybe[T]) -> bool:
    match value:
        Maybe.some:
            return true
        Maybe.none:
            return false


pub def is_none[T](value: Maybe[T]) -> bool:
    return not is_some(value)


pub def value_or[T](value: Maybe[T], fallback: T) -> T:
    match value:
        Maybe.some as payload:
            return payload.value
        Maybe.none:
            return fallback
