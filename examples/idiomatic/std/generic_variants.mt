module examples.idiomatic.std.generic_variants

import std.io as io

variant Maybe[T]:
    some(value: T)
    none

variant Outcome[T, E]:
    ok(value: T)
    err(error: E)


function is_some(value: Maybe[int]) -> bool:
    match value:
        Maybe.some:
            return true
        _:
            return false


function value_or(value: Maybe[int], fallback: int) -> int:
    match value:
        Maybe.some as payload:
            return payload.value
        Maybe.none:
            return fallback


function outcome_code(value: Outcome[int, str]) -> int:
    match value:
        Outcome.ok:
            return 1
        Outcome.err:
            return -1


function outcome_has_error(value: Outcome[int, str]) -> bool:
    match value:
        Outcome.ok:
            return false
        Outcome.err as payload:
            return payload.error.len > 0


function main() -> int:
    let empty: Maybe[int] = Maybe[int].none
    let seeded: Maybe[int] = Maybe[int].some(value= 41)

    let ok_value: Outcome[int, str] = Outcome[int, str].ok(value= 41)
    let err_value: Outcome[int, str] = Outcome[int, str].err(error= "missing")

    if not io.println("generic variant showcase"):
        return 1

    if is_some(empty):
        return 2
    if not is_some(seeded):
        return 3
    if value_or(seeded, 0) != 41:
        return 4
    if value_or(empty, 17) != 17:
        return 5

    if outcome_code(ok_value) != 1:
        return 6
    if outcome_code(err_value) != -1:
        return 7
    if outcome_has_error(ok_value):
        return 8
    if not outcome_has_error(err_value):
        return 9

    if not io.println("generic variant checks passed"):
        return 10

    return 0
