module std.mem.pool

import std.mem.heap as heap

pub struct Pool:
    memory: ptr[byte]
    occupancy: ptr[bool]
    slot_size: usize
    slot_count: usize
    used_count: usize

pub def create(slot_size_bytes: usize, slot_count: usize) -> Pool:
    if slot_size_bytes == 0 or slot_count == 0:
        return Pool(
            memory = heap.alloc[byte](0),
            occupancy = heap.alloc[bool](0),
            slot_size = slot_size_bytes,
            slot_count = 0,
            used_count = 0,
        )

    let total_size = slot_size_bytes * slot_count
    return Pool(
        memory = heap.alloc[byte](total_size),
        occupancy = heap.alloc_zeroed[bool](slot_count),
        slot_size = slot_size_bytes,
        slot_count = slot_count,
        used_count = 0,
    )

methods Pool:
    pub def remaining_slots() -> usize:
        return this.slot_count - this.used_count

    pub edit def alloc_bytes() -> ptr[byte]?:
        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let state_ptr = this.occupancy + index
                if deref(state_ptr) == false:
                    deref(state_ptr) = true
                    this.used_count = this.used_count + 1
                    return this.memory + (index * this.slot_size)
            index = index + 1

        return null

    pub edit def release_bytes(slot: ptr[byte]?) -> bool:
        if slot == null:
            return false

        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let candidate = this.memory + (index * this.slot_size)
                if candidate == slot:
                    let state_ptr = this.occupancy + index
                    if deref(state_ptr) == false:
                        return false

                    deref(state_ptr) = false
                    this.used_count = this.used_count - 1
                    return true
            index = index + 1

        return false

    pub edit def release() -> void:
        heap.release(this.memory)
        heap.release(this.occupancy)
        this.slot_size = 0
        this.slot_count = 0
        this.used_count = 0
        return
