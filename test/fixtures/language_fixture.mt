

import test.fixtures.language_fixture.external_runtime as runtime
import test.fixtures.language_fixture.types as types

const default_step: int = 3

type ExitCode = int

struct AppState:
    counter: types.Counter
    touched: bool

extending AppState:
    static function create() -> AppState:
        return AppState(counter = types.Counter.zero(), touched = false)

    mutable function touch(step: int) -> void:
        this.counter.bump(step)
        this.touched = true

    function read() -> int:
        return this.counter.total

function describe(state: AppState) -> Result[int, int]:
    if state.touched:
        return Result[int, int].success(value= state.read())
    return Result[int, int].failure(error= 9)

function main() -> ExitCode:
    var state = AppState.create()
    defer state.touch(0)
    state.touch(default_step)
    let maybe_value = Option[int].some(value= state.read())
    runtime.puts(c"fixture")
    match maybe_value:
        Option.none:
            return 1
        Option.some as payload:
            let checked = describe(state)
            match checked:
                Result.success as result:
                    return payload.value + result.value - default_step
                Result.failure as result:
                    return result.error
    return 2
