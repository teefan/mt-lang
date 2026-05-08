module std.mem.stack

import std.mem.arena as arena
import std.mem.heap as heap

public type Mark = arena.Mark

public struct Stack:
    arena: arena.Arena


public function create(capacity_bytes: ptr_uint) -> Stack:
    return create_aligned(capacity_bytes, 1)


public function create_aligned(capacity_bytes: ptr_uint, alignment: ptr_uint) -> Stack:
    return Stack(arena = arena.create_aligned(capacity_bytes, alignment))


public function create_for[T](count: ptr_uint) -> Stack:
    return Stack(arena = arena.create_for[T](count))

methods Stack:
    public function mark() -> Mark:
        return this.arena.mark()


    public edit function reset(mark: Mark) -> void:
        this.arena.reset(mark)
        return


    public function remaining_bytes() -> ptr_uint:
        return this.arena.remaining_bytes()


    public edit function alloc_bytes(size_bytes: ptr_uint) -> ptr[ubyte]?:
        return this.arena.alloc_bytes(size_bytes)


    public edit function alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[ubyte]?:
        return this.arena.alloc_bytes_aligned(size_bytes, alignment)


    public edit function alloc[T](count: ptr_uint) -> ptr[T]?:
        return this.arena.alloc[T](count)


    public edit function release() -> void:
        this.arena.release()
        return
