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


    pub edit def release() -> void:
        this.arena.release()
        return


pub def alloc[T](space: ref[Stack], count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
    if heap.mul_overflows(count, element_size):
        return null

    let memory = space.alloc_bytes_aligned(count * element_size, ptr_uint<-align_of(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory
