module std.mem.arena

import std.mem.heap as heap

pub type Mark = usize

pub struct Arena:
    memory: ptr[byte]
    capacity: usize
    offset: usize

pub def create(capacity_bytes: usize) -> Arena:
    return Arena(
        memory = heap.alloc[byte](capacity_bytes),
        capacity = capacity_bytes,
        offset = 0,
    )

methods Arena:
    pub def mark() -> Mark:
        return this.offset

    pub edit def reset(mark: Mark) -> void:
        this.offset = mark
        return

    pub def remaining_bytes() -> usize:
        return this.capacity - this.offset

    pub edit def alloc_bytes(size_bytes: usize) -> ptr[byte]?:
        let next_offset = this.offset + size_bytes
        if next_offset > this.capacity:
            return null

        unsafe:
            let result = this.memory + this.offset
            this.offset = next_offset
            return result

    pub edit def to_cstr(text: str) -> cstr:
        let memory = this.alloc_bytes(text.len + 1)
        if memory == null:
            panic(c"Arena.to_cstr out of memory")

        unsafe:
            let buffer = cast[ptr[char]](memory)
            var index: usize = 0
            while index < text.len:
                deref(buffer + index) = deref(text.data + index)
                index += 1
            deref(buffer + text.len) = zero[char]()
            return cast[cstr](buffer)

    pub edit def release() -> void:
        heap.release(this.memory)
        this.offset = 0
        this.capacity = 0
        return

pub def alloc[T](space: ref[Arena], count: usize) -> ptr[T]?:
    let memory = value(space).alloc_bytes(count * cast[usize](sizeof(T)))
    if memory == null:
        return null

    unsafe:
        return cast[ptr[T]](memory)
