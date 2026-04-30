module std.libuv.async

import std.libuv as uv
import std.libuv.runtime as rt
import std.mem.heap as heap

var current_loop: rt.Loop = zero[rt.Loop]()
var current_loop_active: bool = false

struct SleepState:
    timer: rt.Handle[uv.uv_timer_t]
    ready: bool
    status: i32
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void

struct WorkState[T]:
    request: rt.Request[uv.uv_work_t]
    ready: bool
    status: i32
    result: T
    waiter_frame: ptr[void]?
    waiter: fn(frame: ptr[void]) -> void
    work: fn() -> T

def sleep_state(frame: ptr[void]) -> ptr[SleepState]:
    unsafe:
        return cast[ptr[SleepState]](frame)

def work_state[T](frame: ptr[void]) -> ptr[WorkState[T]]:
    unsafe:
        return cast[ptr[WorkState[T]]](frame)

def require_current_loop() -> rt.Loop:
    if not current_loop_active:
        panic(c"libuv.async requires an active loop; use async.block_on or async.run, or call the explicit *_on helpers")
    return current_loop

def activate_current_loop(loop: rt.Loop) -> void:
    current_loop = loop
    current_loop_active = true
    return

def deactivate_current_loop() -> void:
    current_loop = zero[rt.Loop]()
    current_loop_active = false
    return

def sleep_task(state: ptr[SleepState]) -> Task[i32]:
    unsafe:
        return Task[i32](
            frame = cast[ptr[void]](state),
            ready = sleep_ready,
            set_waiter = sleep_set_waiter,
            release = sleep_release,
            take_result = sleep_take_result,
        )

def work_task[T](state: ptr[WorkState[T]]) -> Task[T]:
    unsafe:
        return Task[T](
            frame = cast[ptr[void]](state),
            ready = work_ready[T],
            set_waiter = work_set_waiter[T],
            release = work_release[T],
            take_result = work_take_result[T],
        )

def complete_sleep(state: ptr[SleepState], status: i32) -> void:
    unsafe:
        deref(state).status = status
        deref(state).ready = true
        let waiter_frame = deref(state).waiter_frame
        if waiter_frame != null:
            deref(state).waiter_frame = null
            deref(state).waiter(waiter_frame)
            return
    return

def complete_work[T](state: ptr[WorkState[T]], status: i32) -> void:
    unsafe:
        deref(state).status = status
        deref(state).ready = true
        let waiter_frame = deref(state).waiter_frame
        if waiter_frame != null:
            deref(state).waiter_frame = null
            deref(state).waiter(waiter_frame)
            return
    return

def on_sleep_closed(handle: ptr[uv.uv_handle_t]) -> void:
    unsafe:
        let state = cast[ptr[SleepState]](uv.handle_get_data(handle))
        complete_sleep(state, deref(state).status)
    return

def on_sleep_timer(timer: ptr[uv.uv_timer_t]) -> void:
    unsafe:
        let handle = cast[ptr[uv.uv_handle_t]](timer)
        let state = cast[ptr[SleepState]](uv.handle_get_data(handle))
        deref(state).status = 0
        uv.close(handle, on_sleep_closed)
    return

def on_work_request[T](req: ptr[uv.uv_work_t]) -> void:
    unsafe:
        let request = cast[ptr[uv.uv_req_t]](req)
        let state = cast[ptr[WorkState[T]]](uv.req_get_data(request))
        deref(state).result = deref(state).work()
    return

def on_work_done[T](req: ptr[uv.uv_work_t], status: i32) -> void:
    unsafe:
        let request = cast[ptr[uv.uv_req_t]](req)
        let state = cast[ptr[WorkState[T]]](uv.req_get_data(request))
        complete_work[T](state, status)
    return

pub def sleep_ready(frame: ptr[void]) -> bool:
    unsafe:
        return deref(sleep_state(frame)).ready

pub def sleep_set_waiter(frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = sleep_state(frame)
    unsafe:
        if deref(state).ready:
            waiter(waiter_frame)
            return
        deref(state).waiter_frame = waiter_frame
        deref(state).waiter = waiter
    return

pub def sleep_release(frame: ptr[void]) -> void:
    let state = sleep_state(frame)
    unsafe:
        if not deref(state).ready:
            return
        if deref(state).timer.storage != null:
            rt.handle_release(addr(deref(state).timer))
    heap.release[SleepState](state)
    return

pub def sleep_take_result(frame: ptr[void]) -> i32:
    unsafe:
        return deref(sleep_state(frame)).status

pub def work_ready[T](frame: ptr[void]) -> bool:
    unsafe:
        return deref(work_state[T](frame)).ready

pub def work_set_waiter[T](frame: ptr[void], waiter_frame: ptr[void], waiter: fn(frame: ptr[void]) -> void) -> void:
    let state = work_state[T](frame)
    unsafe:
        if deref(state).ready:
            waiter(waiter_frame)
            return
        deref(state).waiter_frame = waiter_frame
        deref(state).waiter = waiter
    return

pub def work_release[T](frame: ptr[void]) -> void:
    let state = work_state[T](frame)
    unsafe:
        if not deref(state).ready:
            return
        if deref(state).request.storage != null:
            rt.request_release(addr(deref(state).request))
    heap.release[WorkState[T]](state)
    return

pub def work_take_result[T](frame: ptr[void]) -> T:
    let state = work_state[T](frame)
    unsafe:
        if deref(state).status != 0:
            panic(c"libuv.async.work failed")
        return deref(state).result

pub def sleep_on(loop: rt.Loop, timeout: usize) -> Task[i32]:
    let state = heap.must_alloc_zeroed[SleepState](1)
    let timer_result = rt.create_timer(loop)
    if not timer_result.is_ok:
        unsafe:
            deref(state).status = timer_result.error
            deref(state).ready = true
        return sleep_task(state)

    unsafe:
        deref(state).timer = timer_result.value
        uv.handle_set_data(cast[ptr[uv.uv_handle_t]](rt.handle_ptr(deref(state).timer)), cast[ptr[void]](state))

    var status = 0
    unsafe:
        status = rt.timer_start_once(deref(state).timer, timeout, on_sleep_timer)
    if status != 0:
        unsafe:
            deref(state).status = status
            uv.close(cast[ptr[uv.uv_handle_t]](rt.handle_ptr(deref(state).timer)), on_sleep_closed)
    return sleep_task(state)

pub def sleep(timeout: usize) -> Task[i32]:
    return sleep_on(require_current_loop(), timeout)

pub def work_on[T](loop: rt.Loop, run_work: fn() -> T) -> Task[T]:
    let state = heap.must_alloc_zeroed[WorkState[T]](1)
    unsafe:
        deref(state).work = run_work
        deref(state).request = rt.create_work_request()
        uv.req_set_data(cast[ptr[uv.uv_req_t]](rt.request_ptr(deref(state).request)), cast[ptr[void]](state))

    var status = 0
    unsafe:
        status = rt.queue_work(loop, deref(state).request, on_work_request[T], on_work_done[T])
    if status != 0:
        unsafe:
            rt.request_release(addr(deref(state).request))
        heap.release[WorkState[T]](state)
        panic(c"libuv.async.work queue_work failed")
    return work_task[T](state)

pub def work[T](run_work: fn() -> T) -> Task[T]:
    return work_on[T](require_current_loop(), run_work)

def must_create_loop() -> rt.Loop:
    let loop_result = rt.create_loop()
    if not loop_result.is_ok:
        panic(c"libuv.async.create_loop failed")
    return loop_result.value

def must_release_loop(loop: ref[rt.Loop]) -> void:
    if rt.loop_release(loop) != 0:
        panic(c"libuv.async.loop_release failed")
    return

pub def pump(loop: rt.Loop) -> void:
    rt.loop_run_nowait(loop)
    return

pub def ready[T](task: Task[T]) -> bool:
    return task.ready(task.frame)

pub def finish[T](task: Task[T]) -> T:
    if not ready[T](task):
        panic(c"libuv.async.finish called before task completed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result

pub def block_on_loop[T](loop: rt.Loop, task: Task[T]) -> T:
    while not task.ready(task.frame):
        let status = rt.loop_run_default(loop)
        if status != 0:
            panic(c"libuv.async.block_on loop_run_default failed")

    let result = task.take_result(task.frame)
    task.release(task.frame)
    return result

pub def run_loop(loop: rt.Loop, task: Task[void]) -> void:
    while not task.ready(task.frame):
        let status = rt.loop_run_default(loop)
        if status != 0:
            panic(c"libuv.async.run loop_run_default failed")

    task.take_result(task.frame)
    task.release(task.frame)
    return

pub def block_on[T](root: proc() -> Task[T]) -> T:
    if current_loop_active:
        return block_on_loop[T](current_loop, root())

    var loop = must_create_loop()
    activate_current_loop(loop)
    let result = block_on_loop[T](loop, root())
    deactivate_current_loop()
    must_release_loop(addr(loop))
    return result

pub def run(root: proc() -> Task[void]) -> void:
    if current_loop_active:
        run_loop(current_loop, root())
        return

    var loop = must_create_loop()
    activate_current_loop(loop)
    run_loop(loop, root())
    deactivate_current_loop()
    must_release_loop(addr(loop))
    return
