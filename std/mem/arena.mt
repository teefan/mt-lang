module std.mem.arena

import std.mem.heap as heap

type Mark = usize

struct Arena:
    memory: ptr[byte]
    capacity: usize
    offset: usize

def create(capacity_bytes: usize) -> Arena:
    unsafe:
        return Arena(
            memory = cast[ptr[byte]](heap.alloc(capacity_bytes)),
            capacity = capacity_bytes,
            offset = 0,
        )

methods Arena:
    def mark() -> Mark:
        return this.offset

    edit def reset(mark: Mark) -> void:
        this.offset = mark
        return

    def remaining_bytes() -> usize:
        return this.capacity - this.offset

    edit def alloc_bytes(size_bytes: usize) -> ptr[byte]?:
        let next_offset = this.offset + size_bytes
        if next_offset > this.capacity:
            return null

        unsafe:
            let result = this.memory + this.offset
            this.offset = next_offset
            return result

    edit def release() -> void:
        unsafe:
            heap.release(cast[ptr[void]](this.memory))
        this.offset = 0
        this.capacity = 0
        return
