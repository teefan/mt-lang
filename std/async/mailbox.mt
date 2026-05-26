import std.async as aio
import std.async.libuv_runtime as aio_backend
import std.deque as deque
import std.libuv as libuv
import std.mem.heap as heap
import std.str as text
import std.string as string
import std.sync as sync
import std.vec as vec


type NativeHandle = libuv.uv_handle_t
type NativeAsyncHandle = libuv.uv_async_t


public struct Error:
    code: int
    message: string.String


public struct Mailbox[T]:
    state: ptr[MailboxState[T]]?


struct MailboxStateBase:
    destroy: fn(state_frame: ptr[void]) -> void


struct MailboxState[T]:
    destroy: fn(state_frame: ptr[void]) -> void
    mutex: sync.Mutex
    queue: deque.Deque[T]
    handle: ptr[NativeAsyncHandle]?
    closing: bool


function libuv_error(code: int) -> Error:
    return Error(code = code, message = string.String.from_str(text.cstr_as_str(libuv.strerror(code))))


function mailbox_error(message: str) -> Error:
    return Error(code = -1, message = string.String.from_str(message))


function async_as_handle(handle: ptr[NativeAsyncHandle]) -> ptr[NativeHandle]:
    return unsafe: ptr[NativeHandle]<-handle


function handle_as_async(handle: ptr[NativeHandle]) -> ptr[NativeAsyncHandle]:
    return unsafe: ptr[NativeAsyncHandle]<-handle


function mailbox_async_callback(handle: ptr[NativeAsyncHandle]) -> void:
    unsafe: ptr[NativeAsyncHandle]<-handle
    return


function mailbox_destroy_state[T](state_frame: ptr[void]) -> void:
    let state = unsafe: ptr[MailboxState[T]]<-state_frame

    var mutex = unsafe: read(state).mutex
    mutex.release()

    var queue = unsafe: read(state).queue
    queue.release()

    heap.release(state)


function mailbox_close_callback(handle: ptr[NativeHandle]) -> void:
    let state_raw = libuv.handle_get_data(handle) else:
        unsafe: heap.release_bytes(ptr[void]<-handle_as_async(handle))
        return

    unsafe:
        heap.release_bytes(ptr[void]<-handle_as_async(handle))

    let state_base = unsafe: ptr[MailboxStateBase]<-state_raw
    unsafe: read(state_base).destroy(state_raw)


function alloc_async_handle() -> ptr[NativeAsyncHandle]:
    let handle_size = libuv.handle_size(libuv.uv_handle_type.UV_ASYNC)
    return unsafe: ptr[NativeAsyncHandle]<-heap.must_alloc_zeroed_bytes(1, handle_size)


public function create_on[T](runtime: aio.Runtime) -> Result[Mailbox[T], Error]:
    let mutex_result = sync.create_mutex()
    match mutex_result:
        Result.failure as payload:
            return Result[Mailbox[T], Error].failure(error = Error(code = payload.error.code, message = payload.error.message))
        Result.success as payload:
            let loop = aio_backend.runtime_loop(runtime)
            let handle = alloc_async_handle()
            let state = heap.must_alloc_zeroed[MailboxState[T]](1)
            unsafe:
                state.destroy = mailbox_destroy_state[T]
                state.mutex = payload.value
                state.queue = deque.Deque[T].create()
                state.handle = handle
                state.closing = false
                libuv.handle_set_data(async_as_handle(handle), ptr[void]<-state)

            let status_code = libuv.async_init(loop, handle, mailbox_async_callback)
            if status_code != 0:
                var mutex = payload.value
                mutex.release()
                unsafe: heap.release_bytes(ptr[void]<-handle)
                heap.release(state)
                return Result[Mailbox[T], Error].failure(error = libuv_error(status_code))

            return Result[Mailbox[T], Error].success(value = Mailbox[T](state = state))


public function create[T]() -> Result[Mailbox[T], Error]:
    return create_on[T](aio.current_runtime())


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


extending Mailbox[T]:
    public mutable function release() -> void:
        let state = this.state else:
            return

        this.state = null

        let handle = unsafe: read(state).handle else:
            mailbox_destroy_state[T](unsafe: ptr[void]<-state)
            return

        unsafe: read(state).closing = true
        libuv.close(async_as_handle(handle), mailbox_close_callback)


    public function send(value: T) -> Result[bool, Error]:
        let state = this.state else:
            return Result[bool, Error].failure(error = mailbox_error("mailbox is released"))

        var mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()

        let handle = unsafe: read(state).handle else:
            return Result[bool, Error].failure(error = mailbox_error("mailbox is closed"))

        if unsafe: read(state).closing:
            return Result[bool, Error].failure(error = mailbox_error("mailbox is closed"))

        unsafe: read(state).queue.push_back(value)
        let status_code = libuv.async_send(handle)
        if status_code != 0:
            let rollback = unsafe: read(state).queue.pop_back()
            match rollback:
                Option.none:
                    unsafe: rollback
                Option.some as payload:
                    unsafe: payload.value
            return Result[bool, Error].failure(error = libuv_error(status_code))

        return Result[bool, Error].success(value = true)


    public function try_recv() -> Option[T]:
        let state = this.state else:
            return Option[T].none

        var mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()
        return unsafe: read(state).queue.pop_front()


    public function drain() -> vec.Vec[T]:
        let state = this.state else:
            return vec.Vec[T].create()

        var mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()

        var drained = vec.Vec[T].with_capacity(unsafe: read(state).queue.len())
        while true:
            let message = unsafe: read(state).queue.pop_front()
            match message:
                Option.none:
                    return drained
                Option.some as payload:
                    drained.push(payload.value)


    public function is_empty() -> bool:
        let state = this.state else:
            return true

        var mutex = unsafe: read(state).mutex
        mutex.lock()
        defer mutex.unlock()
        return unsafe: read(state).queue.is_empty()
