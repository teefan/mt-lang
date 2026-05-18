import std.async.runtime as backend

public type Runtime = backend.Runtime


function runtime_create() -> Runtime:
    return backend.runtime_create()


function runtime_activate(runtime: Runtime) -> void:
    backend.runtime_activate(runtime)


function runtime_deactivate() -> void:
    backend.runtime_deactivate()


function runtime_release(runtime: ref[Runtime]) -> void:
    backend.runtime_release(runtime)


function runtime_poll(runtime: Runtime) -> int:
    return backend.runtime_poll(runtime)


public function sleep(timeout: ptr_uint) -> Task[int]:
    return backend.sleep(timeout)


public function create_runtime() -> Result[Runtime, int]:
    return backend.create_runtime()


public function release_runtime(runtime: ref[Runtime]) -> int:
    return backend.release_runtime(runtime)


public function sleep_on(runtime: Runtime, timeout: ptr_uint) -> Task[int]:
    return backend.sleep_on(runtime, timeout)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return backend.work[T](run_work)


public function current_runtime() -> Runtime:
    return backend.current_runtime()


public function work_on[T](runtime: Runtime, run_work: fn() -> T) -> Task[T]:
    return backend.work_on[T](runtime, run_work)


public function pump(runtime: Runtime) -> void:
    backend.pump(runtime)


public function completed[T](task: Task[T]) -> bool:
    return backend.completed[T](task)


public function result[T](task: Task[T]) -> T:
    return backend.result[T](task)


public function wait_on[T](runtime: Runtime, task: Task[T]) -> T:
    return backend.wait_on[T](runtime, task)


public function run_on(runtime: Runtime, task: Task[void]) -> void:
    backend.run_on(runtime, task)


public function wait[T](root: proc() -> Task[T]) -> T:
    return backend.wait[T](root)


public function run(root: proc() -> Task[void]) -> void:
    backend.run(root)


public function with_runtime[T](body: proc(runtime: Runtime) -> T) -> T:
    return backend.with_runtime[T](body)


public function run_with_runtime(body: proc(runtime: Runtime) -> void) -> void:
    backend.run_with_runtime(body)
