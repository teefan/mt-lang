# Standard library: Result type
#
# Result[T, E] represents a fallible computation:
# either Success(T) or Failure(E).
# Imported automatically as part of the language prelude.

public variant Result[T, E]:
    success(value: T)
    failure(error: E)

extending Result[T, E]:
    public function is_success() -> bool:
        match this:
            Result.success:
                return true
            Result.failure:
                return false

    public function is_failure() -> bool:
        match this:
            Result.success:
                return false
            Result.failure:
                return true

    public function unwrap() -> T:
        match this:
            Result.success as payload:
                return payload.value
            Result.failure:
                fatal(c"called Result.unwrap on a failure value")

    public function expect(msg: str) -> T:
        match this:
            Result.success as payload:
                return payload.value
            Result.failure:
                fatal(msg)

    public function unwrap_error() -> E:
        match this:
            Result.success:
                fatal(c"called Result.unwrap_error on a success value")
            Result.failure as payload:
                return payload.error

    public function expect_error(msg: str) -> E:
        match this:
            Result.success:
                fatal(msg)
            Result.failure as payload:
                return payload.error

    public function unwrap_or(default: T) -> T:
        match this:
            Result.success as payload:
                return payload.value
            Result.failure:
                return default

    public function unwrap_or_else(f: proc(error: E) -> T) -> T:
        match this:
            Result.success as payload:
                return payload.value
            Result.failure as payload:
                return f(error=payload.error)
