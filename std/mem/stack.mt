module std.mem.stack

import std.mem.arena as arena
import std.mem.heap as heap

pub type Mark = arena.Mark

pub struct Stack:
    arena: arena.Arena


pub def create(capacity_bytes: ptr_uint) -> Stack:
    return create_aligned(capacity_bytes, 1)


pub def create_aligned(capacity_bytes: ptr_uint, alignment: ptr_uint) -> Stack:
    return Stack(arena = arena.create_aligned(capacity_bytes, alignment))


pub def create_for[T](count: ptr_uint) -> Stack:
    return Stack(arena = arena.create_for[T](count))

methods Stack:
    pub def mark() -> Mark:
        return this.arena.mark()


    pub edit def reset(mark: Mark) -> void:
        this.arena.reset(mark)
        return


    pub def remaining_bytes() -> ptr_uint:
        return this.arena.remaining_bytes()


    pub edit def alloc_bytes(size_bytes: ptr_uint) -> ptr[ubyte]?:
        return this.arena.alloc_bytes(size_bytes)


    pub edit def alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[ubyte]?:
        return this.arena.alloc_bytes_aligned(size_bytes, alignment)


    pub edit def alloc[T](count: ptr_uint) -> ptr[T]?:
        return this.arena.alloc[T](count)


    pub edit def release() -> void:
        this.arena.release()
        return
