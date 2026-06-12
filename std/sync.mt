import std.c.sync as c
import std.libuv as libuv
import std.str as text
import std.string as string

public struct Error:
    code: int
    message: string.String

public struct Mutex:
    handle: ptr[c.mt_mutex]?

public struct Condition:
    handle: ptr[c.mt_condition]?

public struct Semaphore:
    handle: ptr[c.mt_semaphore]?

public struct AtomicUint:
    handle: ptr[c.mt_atomic_uint]?


function libuv_error(code: int) -> Error:
    return Error(code = code, message = string.String.from_str(text.cstr_as_str(libuv.strerror(code))))


function mutex_handle(handle: ptr[c.mt_mutex]?) -> ptr[c.mt_mutex]:
    let live_handle = handle else:
        fatal(c"sync mutex is released")

    return live_handle


function condition_handle(handle: ptr[c.mt_condition]?) -> ptr[c.mt_condition]:
    let live_handle = handle else:
        fatal(c"sync condition is released")

    return live_handle


function semaphore_handle(handle: ptr[c.mt_semaphore]?) -> ptr[c.mt_semaphore]:
    let live_handle = handle else:
        fatal(c"sync semaphore is released")

    return live_handle


public function create_mutex() -> Result[Mutex, Error]:
    var handle: ptr[c.mt_mutex]? = null
    let status_code = c.mt_mutex_create(handle)
    if status_code != 0:
        return Result[Mutex, Error].failure(error = libuv_error(status_code))

    return Result[Mutex, Error].success(value = Mutex(handle = handle))


public function create_recursive_mutex() -> Result[Mutex, Error]:
    var handle: ptr[c.mt_mutex]? = null
    let status_code = c.mt_mutex_create_recursive(handle)
    if status_code != 0:
        return Result[Mutex, Error].failure(error = libuv_error(status_code))

    return Result[Mutex, Error].success(value = Mutex(handle = handle))


public function create_condition() -> Result[Condition, Error]:
    var handle: ptr[c.mt_condition]? = null
    let status_code = c.mt_condition_create(handle)
    if status_code != 0:
        return Result[Condition, Error].failure(error = libuv_error(status_code))

    return Result[Condition, Error].success(value = Condition(handle = handle))


public function create_semaphore(initial_value: uint) -> Result[Semaphore, Error]:
    var handle: ptr[c.mt_semaphore]? = null
    let status_code = c.mt_semaphore_create(initial_value, handle)
    if status_code != 0:
        return Result[Semaphore, Error].failure(error = libuv_error(status_code))

    return Result[Semaphore, Error].success(value = Semaphore(handle = handle))


extending Error:
    public editable function release() -> void:
        this.message.release()


extending Mutex:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        c.mt_mutex_destroy(handle)
        this.handle = null


    public function lock() -> void:
        c.mt_mutex_lock(mutex_handle(this.handle))


    public function try_lock() -> bool:
        return c.mt_mutex_try_lock(mutex_handle(this.handle)) == 0


    public function unlock() -> void:
        c.mt_mutex_unlock(mutex_handle(this.handle))


extending Condition:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        c.mt_condition_destroy(handle)
        this.handle = null


    public function signal() -> void:
        c.mt_condition_signal(condition_handle(this.handle))


    public function broadcast() -> void:
        c.mt_condition_broadcast(condition_handle(this.handle))


    public function wait(mutex: Mutex) -> void:
        c.mt_condition_wait(condition_handle(this.handle), mutex_handle(mutex.handle))


extending Semaphore:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        c.mt_semaphore_destroy(handle)
        this.handle = null


    public function post() -> void:
        c.mt_semaphore_post(semaphore_handle(this.handle))


    public function wait() -> void:
        c.mt_semaphore_wait(semaphore_handle(this.handle))


    public function try_wait() -> bool:
        return c.mt_semaphore_try_wait(semaphore_handle(this.handle)) == 0


public function create_atomic_uint(initial_value: uint) -> AtomicUint:
    var handle: ptr[c.mt_atomic_uint]? = null
    let status_code = c.mt_atomic_uint_create(handle, initial_value)
    if status_code != 0:
        fatal(c"sync.create_atomic_uint failed")

    return AtomicUint(handle = handle)


function atomic_handle(handle: ptr[c.mt_atomic_uint]?) -> ptr[c.mt_atomic_uint]:
    let live_handle = handle else:
        fatal(c"sync AtomicUint is released")

    return live_handle


extending AtomicUint:
    public editable function release() -> void:
        let handle = this.handle else:
            return

        c.mt_atomic_uint_destroy(handle)
        this.handle = null


    public function load() -> uint:
        return c.mt_atomic_uint_load(atomic_handle(this.handle))


    public editable function store(new_value: uint) -> void:
        c.mt_atomic_uint_store(atomic_handle(this.handle), new_value)


    public editable function fetch_add(delta: uint) -> uint:
        return c.mt_atomic_uint_fetch_add(atomic_handle(this.handle), delta)


    public editable function fetch_sub(delta: uint) -> uint:
        return c.mt_atomic_uint_fetch_sub(atomic_handle(this.handle), delta)


    public editable function compare_exchange(expected: ref[uint], desired: uint) -> bool:
        return c.mt_atomic_uint_compare_exchange(atomic_handle(this.handle), ptr_of(expected), desired)
