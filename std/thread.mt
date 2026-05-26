import std.libuv as libuv
import std.mem.heap as heap
import std.str as text
import std.string as string


public type NativeThreadHandle = libuv.uv_thread_t


public struct Error:
    code: int
    message: string.String


public struct Thread:
    handle: ptr[NativeThreadHandle]?


struct RawStartState:
    entry: fn(arg: ptr[void]) -> void
    arg: ptr[void]


struct VoidStartState:
    run: fn() -> void


function libuv_error(code: int) -> Error:
    return Error(code = code, message = string.String.from_str(text.cstr_as_str(libuv.strerror(code))))


function thread_handle(handle: ptr[NativeThreadHandle]?) -> ptr[NativeThreadHandle]:
    let live_handle = handle else:
        fatal(c"thread handle is released")

    return live_handle


function thread_entry_raw(frame: ptr[void]) -> void:
    let state = unsafe: ptr[RawStartState]<-frame
    let entry = unsafe: read(state).entry
    let arg = unsafe: read(state).arg
    heap.release(state)
    entry(arg)


function thread_entry_void(frame: ptr[void]) -> void:
    let state = unsafe: ptr[VoidStartState]<-frame
    let run = unsafe: read(state).run
    heap.release(state)
    run()


public function spawn_raw(entry: fn(arg: ptr[void]) -> void, arg: ptr[void]) -> Result[Thread, Error]:
    let handle = heap.must_alloc_zeroed[NativeThreadHandle](1)
    let state = heap.must_alloc_zeroed[RawStartState](1)
    unsafe:
        state.entry = entry
        state.arg = arg

    let status_code = libuv.thread_create(handle, thread_entry_raw, unsafe: ptr[void]<-state)
    if status_code != 0:
        heap.release(state)
        heap.release(handle)
        return Result[Thread, Error].failure(error = libuv_error(status_code))

    return Result[Thread, Error].success(value = Thread(handle = handle))


public function spawn(run: fn() -> void) -> Result[Thread, Error]:
    let handle = heap.must_alloc_zeroed[NativeThreadHandle](1)
    let state = heap.must_alloc_zeroed[VoidStartState](1)
    unsafe: state.run = run

    let status_code = libuv.thread_create(handle, thread_entry_void, unsafe: ptr[void]<-state)
    if status_code != 0:
        heap.release(state)
        heap.release(handle)
        return Result[Thread, Error].failure(error = libuv_error(status_code))

    return Result[Thread, Error].success(value = Thread(handle = handle))


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


extending Thread:
    public mutable function release() -> void:
        let handle = this.handle else:
            return

        let status_code = libuv.thread_detach(handle)
        if status_code != 0:
            fatal(c"thread release detach failed")

        heap.release(handle)
        this.handle = null


    public function joinable() -> bool:
        return this.handle != null[ptr[NativeThreadHandle]]


    public mutable function join() -> Result[bool, Error]:
        let handle = this.handle else:
            return Result[bool, Error].failure(error = Error(code = -1, message = string.String.from_str("thread handle is released")))

        let status_code = libuv.thread_join(handle)
        if status_code != 0:
            return Result[bool, Error].failure(error = libuv_error(status_code))

        heap.release(handle)
        this.handle = null
        return Result[bool, Error].success(value = true)


    public mutable function detach() -> Result[bool, Error]:
        let handle = this.handle else:
            return Result[bool, Error].failure(error = Error(code = -1, message = string.String.from_str("thread handle is released")))

        let status_code = libuv.thread_detach(handle)
        if status_code != 0:
            return Result[bool, Error].failure(error = libuv_error(status_code))

        heap.release(handle)
        this.handle = null
        return Result[bool, Error].success(value = true)
