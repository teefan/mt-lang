import std.async as aio
import std.async.mailbox as aio_mailbox
import std.deque as deque
import std.mem.heap as heap
import std.string as string
import std.sync as sync
import std.thread as thread
import std.vec as vec

public struct Error:
    code: int
    message: string.String

public struct WorkItem:
    run: fn(arg: ptr[void]) -> void
    complete: fn(arg: ptr[void]) -> void
    arg: ptr[void]

public struct Pool:
    state: ptr[PoolState]?
    workers: vec.Vec[thread.Thread]

struct PoolState:
    mutex: sync.Mutex
    condition: sync.Condition
    queue: deque.Deque[WorkItem]
    queued_jobs: ptr_uint
    running_jobs: ptr_uint
    stopping: bool
    completions: aio_mailbox.Mailbox[WorkItem]


function jobs_error(code: int, message: str) -> Error:
    return Error(code = code, message = string.String.from_str(message))


function error_from_sync(source: sync.Error) -> Error:
    return Error(code = source.code, message = source.message)


function error_from_thread(source: thread.Error) -> Error:
    return Error(code = source.code, message = source.message)


function error_from_mailbox(source: aio_mailbox.Error) -> Error:
    return Error(code = source.code, message = source.message)


function noop_completion(arg: ptr[void]) -> void:
    unsafe: ptr[void]<-arg


function stop_pool_state(state: ptr[PoolState]) -> void:
    let mutex = unsafe: read(state).mutex
    mutex.lock()
    defer mutex.unlock()
    unsafe: read(state).stopping = true
    let condition = unsafe: read(state).condition
    condition.broadcast()


function destroy_pool_state(state: ptr[PoolState]) -> void:
    var completions = unsafe: read(state).completions
    completions.release()

    var queue = unsafe: read(state).queue
    queue.release()

    var condition = unsafe: read(state).condition
    condition.release()

    var mutex = unsafe: read(state).mutex
    mutex.release()

    heap.release(state)


function join_and_release_workers(workers: ref[vec.Vec[thread.Thread]]) -> void:
    while true:
        let maybe_worker = workers.pop()
        match maybe_worker:
            Option.none:
                break
            Option.some as payload:
                var worker = payload.value
                let join_result = worker.join()
                match join_result:
                    Result.failure as join_payload:
                        var error = join_payload.error
                        error.release()
                        fatal(c"jobs worker join failed")
                    Result.success as join_payload:
                        join_payload.value

    workers.release()


function worker_entry(state_raw: ptr[void]) -> void:
    let state = unsafe: ptr[PoolState]<-state_raw
    while true:
        let mutex = unsafe: read(state).mutex
        mutex.lock()

        while true:
            let should_wait = unsafe: not read(state).stopping and read(state).queue.is_empty()
            if not should_wait:
                break

            let condition = unsafe: read(state).condition
            condition.wait(mutex)

        let should_stop = unsafe: read(state).stopping and read(state).queue.is_empty()
        if should_stop:
            mutex.unlock()
            return

        let maybe_job = unsafe: read(state).queue.pop_front()
        match maybe_job:
            Option.none:
                mutex.unlock()
                continue
            Option.some as payload:
                unsafe:
                    read(state).queued_jobs -= 1
                    read(state).running_jobs += 1
                mutex.unlock()

                let item = payload.value
                item.run(item.arg)

                let completions = unsafe: read(state).completions
                let send_result = completions.send(item)
                match send_result:
                    Result.failure as send_payload:
                        var error = send_payload.error
                        error.release()
                    Result.success as send_payload:
                        send_payload.value

                mutex.lock()
                unsafe: read(state).running_jobs -= 1
                mutex.unlock()


public function create_on(runtime: aio.Runtime, worker_count: ptr_uint) -> Result[Pool, Error]:
    if worker_count == 0:
        return Result[Pool, Error].failure(error = jobs_error(-1, "jobs pool requires worker_count > 0"))

    let mutex_result = sync.create_mutex()
    match mutex_result:
        Result.failure as payload:
            return Result[Pool, Error].failure(error = error_from_sync(payload.error))
        Result.success as mutex_payload:
            let condition_result = sync.create_condition()
            match condition_result:
                Result.failure as payload:
                    var mutex = mutex_payload.value
                    mutex.release()
                    return Result[Pool, Error].failure(error = error_from_sync(payload.error))
                Result.success as condition_payload:
                    let mailbox_result = aio_mailbox.create_on[WorkItem](runtime)
                    match mailbox_result:
                        Result.failure as payload:
                            var condition = condition_payload.value
                            condition.release()
                            var mutex = mutex_payload.value
                            mutex.release()
                            return Result[Pool, Error].failure(error = error_from_mailbox(payload.error))
                        Result.success as mailbox_payload:
                            let state = heap.must_alloc_zeroed[PoolState](1)
                            unsafe:
                                state.mutex = mutex_payload.value
                                state.condition = condition_payload.value
                                state.queue = deque.Deque[WorkItem].create()
                                state.queued_jobs = 0
                                state.running_jobs = 0
                                state.stopping = false
                                state.completions = mailbox_payload.value

                            var workers = vec.Vec[thread.Thread].with_capacity(worker_count)
                            var index: ptr_uint = 0
                            while index < worker_count:
                                let spawn_result = thread.spawn_raw(worker_entry, unsafe: ptr[void]<-state)
                                match spawn_result:
                                    Result.failure as payload:
                                        let error = error_from_thread(payload.error)
                                        stop_pool_state(state)
                                        join_and_release_workers(ref_of(workers))
                                        destroy_pool_state(state)
                                        return Result[Pool, Error].failure(error = error)
                                    Result.success as payload:
                                        workers.push(payload.value)
                                index += 1

                            return Result[Pool, Error].success(value = Pool(state = state, workers = workers))


public function create(worker_count: ptr_uint) -> Result[Pool, Error]:
    return create_on(aio.current_runtime(), worker_count)


extending Error:
    public mutable function release() -> void:
        this.message.release()


extending WorkItem:
    public static function create(
        run: fn(arg: ptr[void]) -> void,
        complete: fn(arg: ptr[void]) -> void,
        arg: ptr[void]
    ) -> WorkItem:
        return WorkItem(run = run, complete = complete, arg = arg)


    public static function without_completion(run: fn(arg: ptr[void]) -> void, arg: ptr[void]) -> WorkItem:
        return WorkItem(run = run, complete = noop_completion, arg = arg)


extending Pool:
    public mutable function release() -> void:
        let state = this.state else:
            return

        this.state = null
        stop_pool_state(state)
        join_and_release_workers(ref_of(this.workers))
        destroy_pool_state(state)


    public function submit(item: WorkItem) -> Result[bool, Error]:
        let state = this.state else:
            return Result[bool, Error].failure(error = jobs_error(-1, "jobs pool is released"))

        let mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()

        if unsafe: read(state).stopping:
            return Result[bool, Error].failure(error = jobs_error(-1, "jobs pool is stopping"))

        unsafe:
            read(state).queue.push_back(item)
            read(state).queued_jobs += 1

        let condition = unsafe: read(state).condition
        condition.signal()
        return Result[bool, Error].success(value = true)


    public function try_complete_one() -> bool:
        let state = this.state else:
            return false

        let completions = unsafe: read(state).completions
        match completions.try_recv():
            Option.none:
                return false
            Option.some as payload:
                let item = payload.value
                item.complete(item.arg)
                return true


    public function drain_completed() -> ptr_uint:
        var completed: ptr_uint = 0
        while this.try_complete_one():
            completed += 1
        return completed


    public function queued_jobs() -> ptr_uint:
        let state = this.state else:
            return 0

        let mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()
        return unsafe: read(state).queued_jobs


    public function active_jobs() -> ptr_uint:
        let state = this.state else:
            return 0

        let mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()
        return unsafe: read(state).queued_jobs + read(state).running_jobs


    public function is_idle() -> bool:
        return this.active_jobs() == 0
