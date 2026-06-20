# Standard library: Option type
#
# Option[T] represents an optional value: either Some(T) or None.
# Imported automatically as part of the language prelude.

public variant Option[T]:
    some(value: T)
    none

extending Option[T]:
    public function is_some() -> bool:
        match this:
            Option.some:
                return true
            Option.none:
                return false

    public function is_none() -> bool:
        match this:
            Option.some:
                return false
            Option.none:
                return true

    public function unwrap() -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                fatal(c"called Option.unwrap on a none value")

    public function expect(msg: str) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                fatal(msg)

    public function unwrap_or(default: T) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                return default

    public function unwrap_or_else(f: proc() -> T) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                return f()
