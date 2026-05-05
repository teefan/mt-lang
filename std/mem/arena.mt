module std.mem.arena

import std.mem.heap as heap

pub type Mark = ptr_uint

pub struct Arena:
    memory: ptr[ubyte]?
    capacity: ptr_uint
    offset: ptr_uint


pub def create(capacity_bytes: ptr_uint) -> Arena:
    let memory = heap.alloc[ubyte](capacity_bytes)
    if memory == null and capacity_bytes != 0:
        panic(c"arena.create out of memory")

    return Arena(
        memory = memory,
        capacity = capacity_bytes,
        offset = 0,
    )

methods Arena:
    pub def mark() -> Mark:
        return this.offset


    pub edit def reset(mark: Mark) -> void:
        this.offset = mark
        return


    pub def remaining_bytes() -> ptr_uint:
        return this.capacity - this.offset


    pub edit def alloc_bytes(size_bytes: ptr_uint) -> ptr[ubyte]?:
        return this.alloc_bytes_aligned(size_bytes, 1)


    pub edit def alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[ubyte]?:
        let backing = this.memory
        if backing == null:
            return null
        if alignment == 0:
            return null
        if (alignment & (alignment - 1)) != 0:
            return null

        let mask = alignment - 1
        if this.offset > heap.ptr_uint_max() - mask:
            return null

        let aligned_offset = (this.offset + mask) & ~mask
        if aligned_offset > this.capacity:
            return null
        if size_bytes > this.capacity - aligned_offset:
            return null

        unsafe:
            let result = backing + aligned_offset
            this.offset = aligned_offset + size_bytes
            return result


    pub edit def try_to_cstr(text: str) -> cstr?:
        let memory = this.alloc_bytes(text.len + 1)
        if memory == null:
            return null

        unsafe:
            let buffer = ptr[char]<-memory
            var index: ptr_uint = 0
            while index < text.len:
                read(buffer + index) = read(text.data + index)
                index += 1
            read(buffer + text.len) = zero[char]
            return cstr<-buffer


    pub edit def to_cstr(text: str) -> cstr:
        let memory = this.alloc_bytes(text.len + 1)
        if memory == null:
            panic(c"Arena.to_cstr out of memory")

        unsafe:
            let buffer = ptr[char]<-memory
            var index: ptr_uint = 0
            while index < text.len:
                read(buffer + index) = read(text.data + index)
                index += 1
            read(buffer + text.len) = zero[char]
            return cstr<-buffer


    pub edit def release() -> void:
        heap.release(this.memory)
        this.memory = null
        this.offset = 0
        this.capacity = 0
        return


pub def alloc[T](space: ref[Arena], count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
    if heap.mul_overflows(count, element_size):
        return null

    let memory = space.alloc_bytes_aligned(count * element_size, ptr_uint<-align_of(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory
