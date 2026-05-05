module std.async

import std.libuv.async as impl
import std.libuv.runtime as rt


pub def sleep(timeout: ptr_uint) -> Task[int]:
    return impl.sleep(timeout)


pub def sleep_on(loop: rt.Loop, timeout: ptr_uint) -> Task[int]:
    return impl.sleep_on(loop, timeout)


pub def work[T](run_work: fn() -> T) -> Task[T]:
    return impl.work[T](run_work)


pub def work_on[T](loop: rt.Loop, run_work: fn() -> T) -> Task[T]:
    return impl.work_on[T](loop, run_work)


pub def pump(loop: rt.Loop) -> void:
    impl.pump(loop)
    return


pub def ready[T](task: Task[T]) -> bool:
    return impl.ready[T](task)


pub def finish[T](task: Task[T]) -> T:
    return impl.finish[T](task)


pub def block_on_loop[T](loop: rt.Loop, task: Task[T]) -> T:
    return impl.block_on_loop[T](loop, task)


pub def run_loop(loop: rt.Loop, task: Task[void]) -> void:
    impl.run_loop(loop, task)
    return


pub def block_on[T](root: proc() -> Task[T]) -> T:
    return impl.block_on[T](root)


pub def run(root: proc() -> Task[void]) -> void:
    impl.run(root)
    return
