module std.async.runtime

import std.async.blocking_runtime as backend
import std.status as status


public type Runtime = backend.Runtime


public function runtime_create() -> Runtime:
    return backend.runtime_create()


public function runtime_activate(runtime: Runtime) -> void:
    backend.runtime_activate(runtime)
    return


public function runtime_deactivate() -> void:
    backend.runtime_deactivate()
    return


public function runtime_release(runtime: ref[Runtime]) -> void:
    backend.runtime_release(runtime)
    return


public function runtime_poll(runtime: Runtime) -> int:
    return backend.runtime_poll(runtime)


public function sleep(timeout: ptr_uint) -> Task[int]:
    return backend.sleep(timeout)


public function create_runtime() -> status.Status[Runtime, int]:
    return backend.create_runtime()


public function release_runtime(runtime: ref[Runtime]) -> int:
    return backend.release_runtime(runtime)


public function sleep_on(runtime: Runtime, timeout: ptr_uint) -> Task[int]:
    return backend.sleep_on(runtime, timeout)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return backend.work[T](run_work)


public function work_on[T](runtime: Runtime, run_work: fn() -> T) -> Task[T]:
    return backend.work_on[T](runtime, run_work)


public function pump(runtime: Runtime) -> void:
    backend.pump(runtime)
    return


public function ready[T](task: Task[T]) -> bool:
    return backend.ready[T](task)


public function finish[T](task: Task[T]) -> T:
    return backend.finish[T](task)


public function block_on_runtime[T](runtime: Runtime, task: Task[T]) -> T:
    return backend.block_on_runtime[T](runtime, task)


public function run_runtime(runtime: Runtime, task: Task[void]) -> void:
    backend.run_runtime(runtime, task)
    return


public function block_on[T](root: proc() -> Task[T]) -> T:
    return backend.block_on[T](root)


public function run(root: proc() -> Task[void]) -> void:
    backend.run(root)
    return
