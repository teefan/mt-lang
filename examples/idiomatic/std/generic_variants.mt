module examples.idiomatic.std.generic_variants

import std.io as io

variant Option[T]:
    some(value: T)
    none

variant Outcome[T, E]:
    ok(value: T)
    err(error: E)

def is_some(value: Option[i32]) -> bool:
    match value:
        Option.some:
            return true
        _:
            return false

def unwrap_or(value: Option[i32], fallback: i32) -> i32:
    match value:
        Option.some as payload:
            return payload.value
        Option.none:
            return fallback

def outcome_code(value: Outcome[i32, str]) -> i32:
    match value:
        Outcome.ok:
            return 1
        Outcome.err:
            return -1

def outcome_has_error(value: Outcome[i32, str]) -> bool:
    match value:
        Outcome.ok:
            return false
        Outcome.err as payload:
            return payload.error.len > 0

def main() -> i32:
    let empty: Option[i32] = Option[i32].none
    let seeded: Option[i32] = Option[i32].some(value= 41)

    let ok_value: Outcome[i32, str] = Outcome[i32, str].ok(value= 41)
    let err_value: Outcome[i32, str] = Outcome[i32, str].err(error= "missing")

    if not io.println("generic variant showcase"):
        return 1

    if is_some(empty):
        return 2
    if not is_some(seeded):
        return 3
    if unwrap_or(seeded, 0) != 41:
        return 4
    if unwrap_or(empty, 17) != 17:
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