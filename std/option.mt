# Standard library: Option type
#
# Option[T] represents an optional value: either Some(T) or None.
# Imported automatically as part of the language prelude.

public variant Option[T]:
    some(value: T)
    none

extending Option[T]:
    ## Returns true when the option holds a value.
    public function is_some() -> bool:
        match this:
            Option.some:
                return true
            Option.none:
                return false

    ## Returns true when the option holds no value.
    public function is_none() -> bool:
        match this:
            Option.some:
                return false
            Option.none:
                return true

    ## Returns the contained value or aborts via fatal.
    public function unwrap() -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                fatal(c"called Option.unwrap on a none value")

    ## Returns the contained value or aborts with the given message.
    public function expect(msg: str) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                fatal(msg)

    ## Returns the contained value or a default.
    public function unwrap_or(default: T) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                return default

    ## Returns the contained value or calls a fallback closure.
    public function unwrap_or_else(f: proc() -> T) -> T:
        match this:
            Option.some as payload:
                return payload.value
            Option.none:
                return f()
