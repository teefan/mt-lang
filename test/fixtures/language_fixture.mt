module test.fixtures.language_fixture

import std.maybe as maybe
import std.status as status
import test.fixtures.language_fixture.external_runtime as runtime
import test.fixtures.language_fixture.types as types

const default_step: int = 3

type ExitCode = int

struct AppState:
    counter: types.Counter
    touched: bool

methods AppState:
    static function create() -> AppState:
        return AppState(counter = types.Counter.zero(), touched = false)

    editable function touch(step: int) -> void:
        this.counter.bump(step)
        this.touched = true

    function read() -> int:
        return this.counter.total

function describe(state: AppState) -> status.Status[int, int]:
    if state.touched:
        return status.Status[int, int].ok(value= state.read())
    return status.Status[int, int].err(error= 9)

function main() -> ExitCode:
    var state = AppState.create()
    defer state.touch(0)
    state.touch(default_step)
    let maybe_value = maybe.Maybe[int].some(value= state.read())
    runtime.puts(c"fixture")
    match maybe_value:
        maybe.Maybe.none:
            return 1
        maybe.Maybe.some as payload:
            let checked = describe(state)
            match checked:
                status.Status.ok as result:
                    return payload.value + result.value - default_step
                status.Status.err as result:
                    return result.error
    return 2
