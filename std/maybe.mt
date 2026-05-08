module std.maybe

public variant Maybe[T]:
    some(value: T)
    none


public function is_some[T](value: Maybe[T]) -> bool:
    match value:
        Maybe.some:
            return true
        Maybe.none:
            return false


public function is_none[T](value: Maybe[T]) -> bool:
    return not is_some(value)


public function value_or[T](value: Maybe[T], fallback: T) -> T:
    match value:
        Maybe.some as payload:
            return payload.value
        Maybe.none:
            return fallback
