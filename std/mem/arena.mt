module std.mem.arena

import std.mem.heap as heap

pub type Mark = ptr_uint

pub struct Arena:
    memory: ptr[ubyte]?
    capacity: ptr_uint
    alignment: ptr_uint
    offset: ptr_uint


pub def create(capacity_bytes: ptr_uint) -> Arena:
    return create_aligned(capacity_bytes, 1)


pub def create_aligned(capacity_bytes: ptr_uint, alignment: ptr_uint) -> Arena:
    let normalized_alignment = heap.normalize_alignment(alignment)
    if normalized_alignment == 0:
        panic(c"arena.create_aligned requires a power-of-two alignment")

    let memory = heap.alloc_bytes_aligned(capacity_bytes, normalized_alignment)
    if memory == null:
        if capacity_bytes != 0:
            panic(c"arena.create_aligned out of memory")

        return Arena(
            memory = null,
            capacity = 0,
            alignment = normalized_alignment,
            offset = 0,
        )

    unsafe:
        return Arena(
            memory = ptr[ubyte]<-memory,
            capacity = capacity_bytes,
            alignment = normalized_alignment,
            offset = 0,
        )


pub def create_for[T](count: ptr_uint) -> Arena:
    let element_size = ptr_uint<-size_of(T)
    if heap.mul_overflows(count, element_size):
        panic(c"arena.create_for size overflow")

    return create_aligned(count * element_size, ptr_uint<-align_of(T))

methods Arena:
    pub def mark() -> Mark:
        return this.offset


    pub edit def reset(mark: Mark) -> void:
        if mark > this.offset:
            panic(c"arena.reset invalid mark")

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
        if alignment > this.alignment:
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


    pub edit def alloc[T](count: ptr_uint) -> ptr[T]?:
        let element_size = ptr_uint<-size_of(T)
        if heap.mul_overflows(count, element_size):
            return null

        let memory = this.alloc_bytes_aligned(count * element_size, ptr_uint<-align_of(T))
        if memory == null:
            return null

        unsafe:
            return ptr[T]<-memory


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
        this.capacity = 0
        this.alignment = 0
        this.offset = 0
        return
