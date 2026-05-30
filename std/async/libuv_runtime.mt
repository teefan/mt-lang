import std.libuv as libuv
import std.mem.heap as heap

public type NativeLoopHandle = libuv.uv_loop_t

type NativeHandle = libuv.uv_handle_t
type NativeTimerHandle = libuv.uv_timer_t
type NativeRequest = libuv.uv_req_t
type NativeWorkRequest = libuv.uv_work_t


public struct Runtime:
    loop: ptr[NativeLoopHandle]?
    active: bool


var current_runtime: Runtime = zero[Runtime]
var current_runtime_active: bool = false


struct SleepState:
    ready: bool
    status: int
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    timer: ptr[NativeTimerHandle]?
    closing: bool
    closed: bool
    released: bool


struct WorkState[T]:
    ready: bool
    status: int
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    work: ptr[NativeWorkRequest]?
    queued: bool
    released: bool
    execute: fn(state_frame: ptr[void]) -> void
    run_work: fn() -> T
    result: T


struct WorkStateBase:
    ready: bool
    status: int
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    waiter_registered: bool
    work: ptr[NativeWorkRequest]?
    queued: bool
    released: bool
    execute: fn(state_frame: ptr[void]) -> void


function sleep_state(frame: ptr[void]) -> ptr[SleepState]:
    return unsafe: ptr[SleepState]<-frame


function work_state[T](frame: ptr[void]) -> ptr[WorkState[T]]:
    return unsafe: ptr[WorkState[T]]<-frame


function work_state_base(frame: ptr[void]) -> ptr[WorkStateBase]:
    return unsafe: ptr[WorkStateBase]<-frame


function timer_as_handle(timer: ptr[NativeTimerHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-timer


function handle_as_timer(handle: ptr[NativeHandle]) -> ptr[NativeTimerHandle]:
    return unsafe: ptr[NativeTimerHandle]<-handle


function req_as_work(req: ptr[NativeRequest]) -> ptr[NativeWorkRequest]:
    return unsafe: ptr[NativeWorkRequest]<-req


function work_as_req(work: ptr[NativeWorkRequest]) -> ptr[NativeRequest]:
    return unsafe: ptr[NativeRequest]<-work


function noop_waiter(frame: ptr[void]) -> void:
    unsafe: ptr[void]<-frame


function require_current_runtime() -> Runtime:
    if not current_runtime_active:
        fatal(c"async runtime requires an active runtime; use async.wait or async.run, or call the explicit *_on helpers")
    return current_runtime


function require_live_runtime(runtime: Runtime) -> void:
    if not runtime.active or runtime.loop == null:
        fatal(c"async runtime requires a live runtime")


function live_loop(runtime: Runtime) -> ptr[NativeLoopHandle]:
    require_live_runtime(runtime)
    return unsafe: ptr[NativeLoopHandle]<-runtime.loop


public function current_runtime_handle() -> Runtime:
    return require_current_runtime()


public function runtime_loop(runtime: Runtime) -> ptr[NativeLoopHandle]:
    return live_loop(runtime)


function activate_current_runtime(runtime: Runtime) -> void:
    current_runtime = runtime
    current_runtime_active = true


function deactivate_current_runtime() -> void:
    current_runtime = zero[Runtime]
    current_runtime_active = false


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


function sleep_timer_close(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_timer(handle))
        return

    let state = unsafe: ptr[SleepState]<-state_raw
    unsafe:
        state.closed = true

        let timer = handle_as_timer(handle)
        heap.release_bytes(ptr[void]<-timer)
        state.timer = null

        if state.released:
            heap.release(state)


function sleep_timer_fire(timer: ptr[NativeTimerHandle]) -> void:
    let handle = timer_as_handle(timer)
    let state_raw = libuv.handle_get_data(handle) else:
        return

    let state = unsafe: ptr[SleepState]<-state_raw
    unsafe:
        state.status = 0
        state.ready = true

        if not state.closing and not state.closed:
            state.closing = true
            libuv.timer_stop(timer)
            libuv.close(handle, sleep_timer_close)

        if state.waiter_registered:
            state.waiter(ptr[void]<-state.waiter_frame)


public function runtime_create() -> Runtime:
    let loop_size = libuv.loop_size()
    let loop = unsafe: ptr[NativeLoopHandle]<-heap.must_alloc_zeroed_bytes(1, loop_size)
    let init_status = libuv.loop_init(loop)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-loop)
        fatal(c"async libuv runtime could not initialize event loop")

    return Runtime(loop = loop, active = true)


public function runtime_activate(runtime: Runtime) -> void:
    require_live_runtime(runtime)
    activate_current_runtime(runtime)


public function runtime_deactivate() -> void:
    deactivate_current_runtime()


public function runtime_release(runtime: ref[Runtime]) -> void:
    if release_runtime(runtime) != 0:
        fatal(c"async runtime release failed")


public function runtime_poll(runtime: Runtime) -> int:
    return libuv.run(live_loop(runtime), libuv.uv_run_mode.UV_RUN_ONCE)


public function sleep_ready(frame: ptr[void]) -> bool:
    return unsafe: sleep_state(frame).ready


public function sleep_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = sleep_state(frame)
    unsafe:
        if state.ready:
            waiter(waiter_frame)
            return

        state.waiter_frame = waiter_frame
        state.waiter = waiter
        state.waiter_registered = true


public function sleep_release(frame: ptr[void]) -> void:
    let state = sleep_state(frame)

    unsafe:
        if state.closed:
            heap.release(state)
            return

        state.released = true
        if state.timer == null:
            heap.release(state)
            return

        if not state.closing:
            state.closing = true
            let handle = timer_as_handle(unsafe: ptr[NativeTimerHandle]<-state.timer)
            libuv.close(handle, sleep_timer_close)


public function sleep_take_result(frame: ptr[void]) -> int:
    return unsafe: sleep_state(frame).status


public function work_ready[T](frame: ptr[void]) -> bool:
    return work_state[T](frame).ready


function work_execute(req: ptr[NativeWorkRequest]) -> void:
    let state_raw = libuv.req_get_data(work_as_req(req)) else:
        return

    let state = work_state_base(state_raw)
    unsafe:
        state.execute(ptr[void]<-state)


function work_complete(req: ptr[NativeWorkRequest], status_code: int) -> void:
    let state_raw = libuv.req_get_data(work_as_req(req)) else:
        unsafe: heap.release_bytes(ptr[void]<-req)
        return

    let state = work_state_base(state_raw)
    unsafe:
        state.status = status_code
        state.ready = true
        state.queued = false

        if state.waiter_registered:
            state.waiter(ptr[void]<-state.waiter_frame)

        if state.released:
            if state.work != null:
                heap.release_bytes(ptr[void]<-state.work)
                state.work = null
            heap.release(state)


function work_execute_state[T](state_frame: ptr[void]) -> void:
    let state = work_state[T](state_frame)
    unsafe:
        state.result = state.run_work()


public function work_set_waiter[T](frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = work_state[T](frame)
    unsafe:
        if state.ready:
            waiter(waiter_frame)
            return

        state.waiter_frame = waiter_frame
        state.waiter = waiter
        state.waiter_registered = true


public function work_release[T](frame: ptr[void]) -> void:
    let state = work_state[T](frame)
    unsafe:
        if state.ready:
            if state.work != null:
                heap.release_bytes(ptr[void]<-state.work)
                state.work = null
            heap.release(state)
            return

        state.released = true
        if state.queued and state.work != null:
            libuv.cancel(work_as_req(unsafe: ptr[NativeWorkRequest]<-state.work))


public function work_take_result[T](frame: ptr[void]) -> T:
    let state = work_state[T](frame)
    if state.status != 0:
        fatal(c"async work failed")
    return state.result


public function sleep_on(runtime: Runtime, timeout: ptr_uint) -> Task[int]:
    let loop = live_loop(runtime)

    let state = heap.must_alloc_zeroed[SleepState](1)
    unsafe:
        state.ready = false
        state.status = 0
        state.waiter_frame = null
        state.waiter = noop_waiter
        state.waiter_registered = false
        state.timer = null
        state.closing = false
        state.closed = false
        state.released = false

    let timer_size = libuv.handle_size(libuv.uv_handle_type.UV_TIMER)
    let timer = unsafe: ptr[NativeTimerHandle]<-heap.must_alloc_zeroed_bytes(1, timer_size)
    unsafe: state.timer = timer

    let init_status = libuv.timer_init(loop, timer)
    if init_status != 0:
        unsafe:
            heap.release_bytes(ptr[void]<-timer)
            state.timer = null
            state.closed = true
            state.ready = true
            state.status = init_status
        return sleep_task(state)

    unsafe:
        libuv.handle_set_data(timer_as_handle(timer), ptr[void]<-state)

    let start_status = libuv.timer_start(timer, sleep_timer_fire, timeout, 0)
    if start_status != 0:
        unsafe:
            state.status = start_status
            state.ready = true
            state.closing = true
            libuv.close(timer_as_handle(timer), sleep_timer_close)

    return sleep_task(state)


public function sleep(timeout: ptr_uint) -> Task[int]:
    return sleep_on(require_current_runtime(), timeout)


public function create_runtime() -> Result[Runtime, int]:
    let loop_size = libuv.loop_size()
    let loop = unsafe: ptr[NativeLoopHandle]<-heap.must_alloc_zeroed_bytes(1, loop_size)
    let init_status = libuv.loop_init(loop)
    if init_status != 0:
        unsafe: heap.release_bytes(ptr[void]<-loop)
        return Result[Runtime, int].failure(error= init_status)

    return Result[Runtime, int].success(value= Runtime(loop = loop, active = true))


public function release_runtime(runtime: ref[Runtime]) -> int:
    if not runtime.active:
        return 0

    if current_runtime_active and current_runtime.loop == runtime.loop:
        runtime_deactivate()

    if runtime.loop == null:
        runtime.active = false
        return 0

    let loop = unsafe: ptr[NativeLoopHandle]<-runtime.loop
    var close_status = libuv.loop_close(loop)
    while close_status != 0:
        libuv.run(loop, libuv.uv_run_mode.UV_RUN_DEFAULT)
        close_status = libuv.loop_close(loop)

    unsafe: heap.release_bytes(ptr[void]<-loop)
    runtime.loop = null
    runtime.active = false
    return 0


public function work_on[T](runtime: Runtime, run_work: fn() -> T) -> Task[T]:
    let loop = live_loop(runtime)
    let state = heap.must_alloc_zeroed[WorkState[T]](1)

    let req_size = libuv.req_size(libuv.uv_req_type.UV_WORK)
    let req = unsafe: ptr[NativeWorkRequest]<-heap.must_alloc_zeroed_bytes(1, req_size)

    unsafe:
        state.ready = false
        state.status = 0
        state.execute = work_execute_state[T]
        state.run_work = run_work
        state.waiter_frame = null
        state.waiter = noop_waiter
        state.waiter_registered = false
        state.work = req
        state.queued = false
        state.released = false

        libuv.req_set_data(work_as_req(req), ptr[void]<-state)

    let queue_status = libuv.queue_work(loop, req, work_execute, work_complete)
    unsafe:
        if queue_status != 0:
            state.status = queue_status
            state.ready = true
            state.queued = false
        else:
            state.queued = true

    return work_task[T](state)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return work_on[T](require_current_runtime(), run_work)


public function pump(runtime: Runtime) -> void:
    require_live_runtime(runtime)
    runtime_poll(runtime)


public function completed[T](task: Task[T]) -> bool:
    return task.ready(task.frame)


public function result[T](task: Task[T]) -> T:
    if not completed[T](task):
        fatal(c"async.result called before task completed")

    defer task.release(task.frame)
    return task.take_result(task.frame)


public function wait_on[T](runtime: Runtime, task: Task[T]) -> T:
    require_live_runtime(runtime)
    while not task.ready(task.frame):
        runtime_poll(runtime)

    defer task.release(task.frame)
    return task.take_result(task.frame)


public function run_on(runtime: Runtime, task: Task[void]) -> void:
    require_live_runtime(runtime)
    while not task.ready(task.frame):
        runtime_poll(runtime)

    task.take_result(task.frame)
    task.release(task.frame)


public function wait[T](root: proc() -> Task[T]) -> T:
    if current_runtime_active:
        return wait_on[T](current_runtime, root())

    var runtime = runtime_create()
    runtime_activate(runtime)
    defer runtime_release(ref_of(runtime))
    defer runtime_deactivate()
    return wait_on[T](runtime, root())


public function run(root: proc() -> Task[void]) -> void:
    if current_runtime_active:
        run_on(current_runtime, root())
        return

    var runtime = runtime_create()
    runtime_activate(runtime)
    defer runtime_release(ref_of(runtime))
    defer runtime_deactivate()
    run_on(runtime, root())


public function with_runtime[T](body: proc(runtime: Runtime) -> T) -> T:
    if current_runtime_active:
        return body(current_runtime)

    var runtime = runtime_create()
    runtime_activate(runtime)
    defer runtime_release(ref_of(runtime))
    defer runtime_deactivate()
    return body(runtime)


public function run_with_runtime(body: proc(runtime: Runtime) -> void) -> void:
    if current_runtime_active:
        body(current_runtime)
        return

    var runtime = runtime_create()
    runtime_activate(runtime)
    defer runtime_release(ref_of(runtime))
    defer runtime_deactivate()
    body(runtime)
