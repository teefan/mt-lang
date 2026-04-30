module std.mem.pool

import std.mem.heap as heap

pub struct Pool:
    memory: ptr[byte]?
    occupancy: ptr[bool]?
    slot_size: usize
    slot_count: usize
    used_count: usize

pub def create(slot_size_bytes: usize, slot_count: usize) -> Pool:
    if slot_size_bytes == 0 or slot_count == 0:
        return Pool(
            memory = null,
            occupancy = null,
            slot_size = slot_size_bytes,
            slot_count = 0,
            used_count = 0,
        )

    if heap.mul_overflows(slot_size_bytes, slot_count):
        panic(c"pool.create size overflow")

    let total_size = slot_size_bytes * slot_count
    let memory = heap.alloc[byte](total_size)
    if memory == null:
        panic(c"pool.create out of memory")

    let occupancy = heap.alloc_zeroed[bool](slot_count)
    if occupancy == null:
        heap.release(memory)
        panic(c"pool.create occupancy out of memory")

    return Pool(
        memory = memory,
        occupancy = occupancy,
        slot_size = slot_size_bytes,
        slot_count = slot_count,
        used_count = 0,
    )

pub def slot_size_for[T]() -> usize:
    let size = usize<-sizeof(T)
    let alignment = usize<-alignof(T)
    let mask = alignment - 1
    if size > heap.usize_max() - mask:
        panic(c"pool.slot_size_for overflow")

    return (size + mask) & ~mask

pub def create_for[T](slot_count: usize) -> Pool:
    let size = usize<-sizeof(T)
    let alignment = usize<-alignof(T)
    let mask = alignment - 1
    if size > heap.usize_max() - mask:
        panic(c"pool.create_for slot size overflow")

    return create((size + mask) & ~mask, slot_count)

methods Pool:
    pub def remaining_slots() -> usize:
        return this.slot_count - this.used_count

    pub edit def alloc_bytes() -> ptr[byte]?:
        let memory = this.memory
        if memory == null:
            return null
        let occupancy = this.occupancy
        if occupancy == null:
            return null

        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let state_ptr = ptr[bool]<-occupancy + index
                if read(state_ptr) == false:
                    read(state_ptr) = true
                    this.used_count = this.used_count + 1
                    return ptr[byte]<-memory + (index * this.slot_size)
            index = index + 1

        return null

    pub edit def release_bytes(slot: ptr[byte]?) -> bool:
        if slot == null:
            return false

        let memory = this.memory
        if memory == null:
            return false
        let occupancy = this.occupancy
        if occupancy == null:
            return false

        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let candidate = ptr[byte]<-memory + (index * this.slot_size)
                if candidate == ptr[byte]<-slot:
                    let state_ptr = ptr[bool]<-occupancy + index
                    if read(state_ptr) == false:
                        return false

                    read(state_ptr) = false
                    this.used_count = this.used_count - 1
                    return true
            index = index + 1

        return false

    pub edit def release() -> void:
        heap.release(this.memory)
        heap.release(this.occupancy)
        this.memory = null
        this.occupancy = null
        this.slot_size = 0
        this.slot_count = 0
        this.used_count = 0
        return

pub def alloc[T](space: ref[Pool]) -> ptr[T]?:
    let size = usize<-sizeof(T)
    let alignment = usize<-alignof(T)
    let mask = alignment - 1
    if size > heap.usize_max() - mask:
        return null

    let slot_size = (size + mask) & ~mask
    if space.slot_size < slot_size:
        return null

    let memory = space.alloc_bytes()
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory

pub def release[T](space: ref[Pool], slot: ptr[T]?) -> bool:
    if slot == null:
        return false

    unsafe:
        return space.release_bytes(ptr[byte]<-slot)
