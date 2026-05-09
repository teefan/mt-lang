module std.libuv.async

import std.libuv as uv
import std.libuv.runtime as rt
import std.mem.heap as heap
import std.status as status

var current_loop: rt.Loop = zero[rt.Loop]
var current_loop_active: bool = false

struct SleepState:
    timer: rt.Handle[uv.uv_timer_t]
    ready: bool
    status: int
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void

struct WorkState[T]:
    request: rt.Request[uv.uv_work_t]
    ready: bool
    status: int
    result: T
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    work: fn() -> T


function sleep_state(frame: ptr[void]) -> ptr[SleepState]:
    return unsafe: ptr[SleepState]<-frame


function work_state[T](frame: ptr[void]) -> ptr[WorkState[T]]:
    return unsafe: ptr[WorkState[T]]<-frame


function require_current_loop() -> rt.Loop:
    if not current_loop_active:
        panic(c"libuv.async requires an active loop; use async.block_on or async.run, or call the explicit *_on helpers")
    return current_loop


function activate_current_loop(loop: rt.Loop) -> void:
    current_loop = loop
    current_loop_active = true
    return


function deactivate_current_loop() -> void:
    current_loop = zero[rt.Loop]
    current_loop_active = false
    return


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


function complete_sleep(state: ptr[SleepState], status: int) -> void:
    unsafe:
        state.status = status
        state.ready = true
        let waiter_frame = state.waiter_frame
        if waiter_frame != null:
            state.waiter_frame = null
            state.waiter(waiter_frame)
            return
    return


function complete_work[T](state: ptr[WorkState[T]], status: int) -> void:
    unsafe:
        state.status = status
        state.ready = true
        let waiter_frame = state.waiter_frame
        if waiter_frame != null:
            state.waiter_frame = null
            state.waiter(waiter_frame)
            return
    return


function on_sleep_closed(handle: ptr[uv.uv_handle_t]) -> void:
    unsafe:
        let state = ptr[SleepState]<-uv.handle_get_data(handle)
        complete_sleep(state, state.status)
    return


function on_sleep_timer(timer: ptr[uv.uv_timer_t]) -> void:
    unsafe:
        let handle = ptr[uv.uv_handle_t]<-timer
        let state = ptr[SleepState]<-uv.handle_get_data(handle)
        state.status = 0
        uv.close(handle, on_sleep_closed)
    return


function on_work_request[T](req: ptr[uv.uv_work_t]) -> void:
    unsafe:
        let request = ptr[uv.uv_req_t]<-req
        let state = ptr[WorkState[T]]<-uv.req_get_data(request)
        state.result = state.work()
    return


function on_work_done[T](req: ptr[uv.uv_work_t], status: int) -> void:
    unsafe:
        let request = ptr[uv.uv_req_t]<-req
        let state = ptr[WorkState[T]]<-uv.req_get_data(request)
        complete_work[T](state, status)
    return


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
    return


public function sleep_release(frame: ptr[void]) -> void:
    let state = sleep_state(frame)
    unsafe:
        if not state.ready:
            return
        if state.timer.storage != null:
            rt.handle_release(ref_of(state.timer))
    heap.release[SleepState](state)
    return


public function sleep_take_result(frame: ptr[void]) -> int:
    return unsafe: sleep_state(frame).status


public function work_ready[T](frame: ptr[void]) -> bool:
    return unsafe: work_state[T](frame).ready


public function work_set_waiter[T](frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = work_state[T](frame)
    unsafe:
        if state.ready:
            waiter(waiter_frame)
            return
        state.waiter_frame = waiter_frame
        state.waiter = waiter
    return


public function work_release[T](frame: ptr[void]) -> void:
    let state = work_state[T](frame)
    unsafe:
        if not state.ready:
            return
        if state.request.storage != null:
            rt.request_release(ref_of(state.request))
    heap.release[WorkState[T]](state)
    return


public function work_take_result[T](frame: ptr[void]) -> T:
    let state = work_state[T](frame)
    unsafe:
        if state.status != 0:
            panic(c"libuv.async.work failed")
        return state.result


public function sleep_on(loop: rt.Loop, timeout: ptr_uint) -> Task[int]:
    let state = heap.must_alloc_zeroed[SleepState](1)
    let timer_result = rt.create_timer(loop)
    match timer_result:
        status.Status.err as payload:
            unsafe:
                state.status = payload.error
                state.ready = true
            return sleep_task(state)
        status.Status.ok as payload:
            unsafe:
                state.timer = payload.value
                uv.handle_set_data(ptr[uv.uv_handle_t]<-rt.handle_ptr(state.timer), ptr[void]<-state)

    var code = 0
    code = unsafe: rt.timer_start_once(state.timer, timeout, on_sleep_timer)
    if code != 0:
        unsafe:
            state.status = code
            uv.close(ptr[uv.uv_handle_t]<-rt.handle_ptr(state.timer), on_sleep_closed)
    return sleep_task(state)


public function sleep(timeout: ptr_uint) -> Task[int]:
    return sleep_on(require_current_loop(), timeout)


public function work_on[T](loop: rt.Loop, run_work: fn() -> T) -> Task[T]:
    let state = heap.must_alloc_zeroed[WorkState[T]](1)
    unsafe:
        state.work = run_work
        state.request = rt.create_work_request()
        uv.req_set_data(ptr[uv.uv_req_t]<-rt.request_ptr(state.request), ptr[void]<-state)

    var status = 0
    status = unsafe: rt.queue_work(loop, state.request, on_work_request[T], on_work_done[T])
    if status != 0:
        unsafe: rt.request_release(ref_of(state.request))
        heap.release[WorkState[T]](state)
        panic(c"libuv.async.work queue_work failed")
    return work_task[T](state)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return work_on[T](require_current_loop(), run_work)


function must_create_loop() -> rt.Loop:
    let loop_result = rt.create_loop()
    match loop_result:
        status.Status.ok as payload:
            return payload.value
        status.Status.err:
            panic(c"libuv.async.create_loop failed")
    return zero[rt.Loop]


function must_release_loop(loop: ref[rt.Loop]) -> void:
    if rt.loop_release(loop) != 0:
        panic(c"libuv.async.loop_release failed")
    return


public function pump(loop: rt.Loop) -> void:
    rt.loop_run_nowait(loop)
    return


public function ready[T](task: Task[T]) -> bool:
    return task.ready(task.frame)


public function finish[T](task: Task[T]) -> T:
    if not ready[T](task):
        panic(c"libuv.async.finish called before task completed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result


public function block_on_loop[T](loop: rt.Loop, task: Task[T]) -> T:
    while not task.ready(task.frame):
        let status = rt.loop_run_default(loop)
        if status != 0:
            panic(c"libuv.async.block_on loop_run_default failed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result


public function run_loop(loop: rt.Loop, task: Task[void]) -> void:
    while not task.ready(task.frame):
        let status = rt.loop_run_default(loop)
        if status != 0:
            panic(c"libuv.async.run loop_run_default failed")

    task.take_result(task.frame)
    task.release(task.frame)
    return


public function block_on[T](root: proc() -> Task[T]) -> T:
    if current_loop_active:
        return block_on_loop[T](current_loop, root())

    var loop = must_create_loop()
    activate_current_loop(loop)
    let result = block_on_loop[T](loop, root())
    deactivate_current_loop()
    must_release_loop(ref_of(loop))
    return result


public function run(root: proc() -> Task[void]) -> void:
    if current_loop_active:
        run_loop(current_loop, root())
        return

    var loop = must_create_loop()
    activate_current_loop(loop)
    run_loop(loop, root())
    deactivate_current_loop()
    must_release_loop(ref_of(loop))
    return
