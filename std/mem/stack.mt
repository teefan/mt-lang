module std.mem.stack

import std.mem.arena as arena

type Mark = arena.Mark

struct Stack:
    arena: arena.Arena

def create(capacity_bytes: usize) -> Stack:
    return Stack(arena = arena.create(capacity_bytes))

methods Stack:
    def mark() -> Mark:
        return this.arena.mark()

    edit def reset(mark: Mark) -> void:
        this.arena.reset(mark)
        return

    def remaining_bytes() -> usize:
        return this.arena.remaining_bytes()

    edit def alloc_bytes(size_bytes: usize) -> ptr[byte]?:
        return this.arena.alloc_bytes(size_bytes)

    edit def release() -> void:
        this.arena.release()
        return

def alloc[T](space: ref[Stack], count: usize) -> ptr[T]?:
    let memory = value(space).alloc_bytes(count * cast[usize](sizeof(T)))
    if memory == null:
        return null

    unsafe:
        return cast[ptr[T]](memory)
