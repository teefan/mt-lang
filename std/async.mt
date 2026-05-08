module std.async

import std.libuv.async as impl
import std.libuv.runtime as rt


public function sleep(timeout: ptr_uint) -> Task[int]:
    return impl.sleep(timeout)


public function sleep_on(loop: rt.Loop, timeout: ptr_uint) -> Task[int]:
    return impl.sleep_on(loop, timeout)


public function work[T](run_work: fn() -> T) -> Task[T]:
    return impl.work[T](run_work)


public function work_on[T](loop: rt.Loop, run_work: fn() -> T) -> Task[T]:
    return impl.work_on[T](loop, run_work)


public function pump(loop: rt.Loop) -> void:
    impl.pump(loop)
    return


public function ready[T](task: Task[T]) -> bool:
    return impl.ready[T](task)


public function finish[T](task: Task[T]) -> T:
    return impl.finish[T](task)


public function block_on_loop[T](loop: rt.Loop, task: Task[T]) -> T:
    return impl.block_on_loop[T](loop, task)


public function run_loop(loop: rt.Loop, task: Task[void]) -> void:
    impl.run_loop(loop, task)
    return


public function block_on[T](root: proc() -> Task[T]) -> T:
    return impl.block_on[T](root)


public function run(root: proc() -> Task[void]) -> void:
    impl.run(root)
    return
