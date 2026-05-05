module std.mem.pool

import std.mem.heap as heap


def slot_alignment(slot_size_bytes: ptr_uint, base_alignment: ptr_uint) -> ptr_uint:
    if slot_size_bytes == 0:
        return base_alignment

    var alignment = base_alignment
    while alignment > 1 and (slot_size_bytes & (alignment - 1)) != 0:
        alignment = alignment / 2

    return alignment

pub struct Pool:
    memory: ptr[ubyte]?
    occupancy: ptr[bool]?
    slot_size: ptr_uint
    slot_alignment: ptr_uint
    slot_count: ptr_uint
    used_count: ptr_uint


pub def create(slot_size_bytes: ptr_uint, slot_count: ptr_uint) -> Pool:
    return create_aligned(slot_size_bytes, slot_count, 1)


pub def create_aligned(slot_size_bytes: ptr_uint, slot_count: ptr_uint, alignment: ptr_uint) -> Pool:
    let normalized_alignment = heap.normalize_alignment(alignment)
    if normalized_alignment == 0:
        panic(c"pool.create_aligned requires a power-of-two alignment")

    if slot_size_bytes == 0 or slot_count == 0:
        return Pool(
            memory = null,
            occupancy = null,
            slot_size = slot_size_bytes,
            slot_alignment = slot_alignment(slot_size_bytes, normalized_alignment),
            slot_count = 0,
            used_count = 0,
        )

    if heap.mul_overflows(slot_size_bytes, slot_count):
        panic(c"pool.create size overflow")

    let total_size = slot_size_bytes * slot_count
    let memory = heap.alloc_bytes_aligned(total_size, normalized_alignment)
    if memory == null:
        panic(c"pool.create_aligned out of memory")

    let occupancy = heap.alloc_zeroed[bool](slot_count)
    if occupancy == null:
        heap.release_bytes(memory)
        panic(c"pool.create occupancy out of memory")

    unsafe:
        return Pool(
            memory = ptr[ubyte]<-memory,
            occupancy = occupancy,
            slot_size = slot_size_bytes,
            slot_alignment = slot_alignment(slot_size_bytes, normalized_alignment),
            slot_count = slot_count,
            used_count = 0,
        )


pub def slot_size_for[T]() -> ptr_uint:
    let size = ptr_uint<-size_of(T)
    let alignment = ptr_uint<-align_of(T)
    let mask = alignment - 1
    if size > heap.ptr_uint_max() - mask:
        panic(c"pool.slot_size_for overflow")

    return (size + mask) & ~mask


pub def create_for[T](slot_count: ptr_uint) -> Pool:
    return create_aligned(slot_size_for[T](), slot_count, ptr_uint<-align_of(T))

methods Pool:
    pub def remaining_slots() -> ptr_uint:
        return this.slot_count - this.used_count


    pub edit def alloc_bytes() -> ptr[ubyte]?:
        let memory = this.memory
        if memory == null:
            return null
        let occupancy = this.occupancy
        if occupancy == null:
            return null

        var index: ptr_uint = 0
        while index < this.slot_count:
            unsafe:
                let state_ptr = ptr[bool]<-occupancy + index
                if read(state_ptr) == false:
                    read(state_ptr) = true
                    this.used_count = this.used_count + 1
                    return ptr[ubyte]<-memory + (index * this.slot_size)
            index = index + 1

        return null


    pub edit def alloc[T]() -> ptr[T]?:
        let size = ptr_uint<-size_of(T)
        let alignment = ptr_uint<-align_of(T)
        let mask = alignment - 1
        if size > heap.ptr_uint_max() - mask:
            return null

        let slot_size = (size + mask) & ~mask
        if this.slot_alignment < alignment:
            return null
        if this.slot_size < slot_size:
            return null

        let memory = this.alloc_bytes()
        if memory == null:
            return null

        unsafe:
            return ptr[T]<-memory


    pub edit def release_bytes(slot: ptr[ubyte]?) -> bool:
        if slot == null:
            return false

        let memory = this.memory
        if memory == null:
            return false
        let occupancy = this.occupancy
        if occupancy == null:
            return false

        var index: ptr_uint = 0
        while index < this.slot_count:
            unsafe:
                let candidate = ptr[ubyte]<-memory + (index * this.slot_size)
                if candidate == ptr[ubyte]<-slot:
                    let state_ptr = ptr[bool]<-occupancy + index
                    if read(state_ptr) == false:
                        return false

                    read(state_ptr) = false
                    this.used_count = this.used_count - 1
                    return true
            index = index + 1

        return false


    pub edit def release_slot[T](slot: ptr[T]?) -> bool:
        if slot == null:
            return false

        unsafe:
            return this.release_bytes(ptr[ubyte]<-slot)


    pub edit def release() -> void:
        heap.release(this.memory)
        heap.release(this.occupancy)
        this.memory = null
        this.occupancy = null
        this.slot_size = 0
        this.slot_alignment = 0
        this.slot_count = 0
        this.used_count = 0
        return
