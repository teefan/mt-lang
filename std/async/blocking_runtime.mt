module std.async.blocking_runtime

import std.c.time as c
import std.mem.heap as heap
import std.status as status


const milliseconds_per_second: ptr_uint = 1000
const nanoseconds_per_millisecond: ptr_uint = 1000000


public struct Runtime:
    active: bool


var current_runtime: Runtime = zero[Runtime]
var current_runtime_active: bool = false


struct SleepState:
    ready: bool
    status: int


struct WorkState[T]:
    ready: bool
    status: int
    result: T


function sleep_state(frame: ptr[void]) -> ptr[SleepState]:
    return unsafe: ptr[SleepState]<-frame


function work_state[T](frame: ptr[void]) -> ptr[WorkState[T]]:
    return unsafe: ptr[WorkState[T]]<-frame


function require_current_runtime() -> Runtime:
    if not current_runtime_active:
        fatal(c"async runtime requires an active runtime; use async.block_on or async.run, or call the explicit *_on helpers")
    return current_runtime


function require_live_runtime(runtime: Runtime) -> void:
    if not runtime.active:
        fatal(c"async runtime requires a live runtime")
    return


function activate_current_runtime(runtime: Runtime) -> void:
    current_runtime = runtime
    current_runtime_active = true
    return


function deactivate_current_runtime() -> void:
    current_runtime = zero[Runtime]
    current_runtime_active = false
    return


function duration_from_milliseconds(timeout: ptr_uint) -> c.timespec:
    let seconds = timeout / milliseconds_per_second
    let milliseconds = timeout % milliseconds_per_second
    return c.timespec(
        tv_sec = ptr_int<-seconds,
        tv_nsec = ptr_int<-(milliseconds * nanoseconds_per_millisecond),
    )


function sleep_blocking(timeout: ptr_uint) -> int:
    var duration = duration_from_milliseconds(timeout)
    return c.nanosleep(ptr_of(duration), null)


function sleep_task(state: ptr[SleepState]) -> Task[int]:
    return unsafe: Task[int](
            frame = ptr[void]<-state,
            ready = sleep_ready,
            set_waiter = sleep_set_waiter,
            release = sleep_release,
            take_result = sleep_take_result,
        )


function work_task[T](state: ptr[WorkState[T]]) -> Task[T]:
    return unsafe: Task[T](
            frame = ptr[void]<-state,
            ready = work_ready[T],
            set_waiter = work_set_waiter[T],
            release = work_release[T],
            take_result = work_take_result[T],
        )


public function runtime_create() -> Runtime:
    return Runtime(active = true)


public function runtime_activate(runtime: Runtime) -> void:
    require_live_runtime(runtime)
    activate_current_runtime(runtime)
    return


public function runtime_deactivate() -> void:
    deactivate_current_runtime()
    return


public function runtime_release(runtime: ref[Runtime]) -> void:
    if release_runtime(runtime) != 0:
        fatal(c"async runtime release failed")
    return


public function runtime_poll(runtime: Runtime) -> int:
    require_live_runtime(runtime)
    return 0


public function sleep_ready(frame: ptr[void]) -> bool:
    return unsafe: sleep_state(frame).ready


public function sleep_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = sleep_state(frame)
    unsafe:
        if not state.ready:
            fatal(c"blocking runtime only supports ready sleep tasks")
        waiter(waiter_frame)
    return


public function sleep_release(frame: ptr[void]) -> void:
    let state = sleep_state(frame)
    unsafe: heap.release_bytes(ptr[void]<-state)
    return


public function sleep_take_result(frame: ptr[void]) -> int:
    return unsafe: sleep_state(frame).status


public function work_ready[T](frame: ptr[void]) -> bool:
    return unsafe: work_state[T](frame).ready


public function work_set_waiter[T](frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = work_state[T](frame)
    unsafe:
        if not state.ready:
            fatal(c"blocking runtime only supports ready work tasks")
        waiter(waiter_frame)
    return


public function work_release[T](frame: ptr[void]) -> void:
    let state = work_state[T](frame)
    unsafe: heap.release_bytes(ptr[void]<-state)
    return


public function work_take_result[T](frame: ptr[void]) -> T:
    let state = work_state[T](frame)
    unsafe:
        if state.status != 0:
            fatal(c"async work failed")
        return state.result


public function sleep_on(runtime: Runtime, timeout: ptr_uint) -> Task[int]:
    require_live_runtime(runtime)
    let state = heap.must_alloc_zeroed[SleepState](1)
    unsafe:
        state.status = sleep_blocking(timeout)
        state.ready = true
    return sleep_task(state)


public function sleep(timeout: ptr_uint) -> Task[int]:
    return sleep_on(require_current_runtime(), timeout)


public function create_runtime() -> status.Status[Runtime, int]:
    return status.Status[Runtime, int].ok(value= runtime_create())


public function release_runtime(runtime: ref[Runtime]) -> int:
    runtime.active = false
    return 0


public function work_on[T](runtime: Runtime, run_work: fn() -> T) -> Task[T]:
    require_live_runtime(runtime)
    let state = heap.must_alloc_zeroed[WorkState[T]](1)
    unsafe:
        state.result = run_work()
        state.status = 0
        state.ready = true
    return work_task[T](state)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return work_on[T](require_current_runtime(), run_work)


public function pump(runtime: Runtime) -> void:
    require_live_runtime(runtime)
    return


public function ready[T](task: Task[T]) -> bool:
    return task.ready(task.frame)


public function finish[T](task: Task[T]) -> T:
    if not ready[T](task):
        fatal(c"async.finish called before task completed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result


public function block_on_runtime[T](runtime: Runtime, task: Task[T]) -> T:
    require_live_runtime(runtime)
    while not task.ready(task.frame):
        let status_code = runtime_poll(runtime)
        if status_code != 0:
            fatal(c"async.block_on loop_run_default failed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result


public function run_runtime(runtime: Runtime, task: Task[void]) -> void:
    require_live_runtime(runtime)
    while not task.ready(task.frame):
        let status_code = runtime_poll(runtime)
        if status_code != 0:
            fatal(c"async.run loop_run_default failed")

    task.take_result(task.frame)
    task.release(task.frame)
    return


public function block_on[T](root: proc() -> Task[T]) -> T:
    if current_runtime_active:
        return block_on_runtime[T](current_runtime, root())

    var runtime = runtime_create()
    runtime_activate(runtime)
    let result = block_on_runtime[T](runtime, root())
    runtime_deactivate()
    runtime_release(ref_of(runtime))
    return result


public function run(root: proc() -> Task[void]) -> void:
    if current_runtime_active:
        run_runtime(current_runtime, root())
        return

    var runtime = runtime_create()
    runtime_activate(runtime)
    run_runtime(runtime, root())
    runtime_deactivate()
    runtime_release(ref_of(runtime))
    return
