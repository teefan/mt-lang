module std.mem.pool

import std.mem.heap as heap

struct Pool:
    memory: ptr[byte]
    occupancy: ptr[bool]
    slot_size: usize
    slot_count: usize
    used_count: usize

def create(slot_size_bytes: usize, slot_count: usize) -> Pool:
    if slot_size_bytes == 0 or slot_count == 0:
        unsafe:
            return Pool(
                memory = cast[ptr[byte]](heap.alloc(0)),
                occupancy = cast[ptr[bool]](heap.alloc(0)),
                slot_size = slot_size_bytes,
                slot_count = 0,
                used_count = 0,
            )

    let total_size = slot_size_bytes * slot_count
    unsafe:
        return Pool(
            memory = cast[ptr[byte]](heap.alloc(total_size)),
            occupancy = cast[ptr[bool]](heap.alloc_zeroed(slot_count, 1)),
            slot_size = slot_size_bytes,
            slot_count = slot_count,
            used_count = 0,
        )

methods Pool:
    def remaining_slots() -> usize:
        return this.slot_count - this.used_count

    edit def alloc_bytes() -> ptr[byte]?:
        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let state_ptr = this.occupancy + index
                if *state_ptr == false:
                    *state_ptr = true
                    this.used_count = this.used_count + 1
                    return this.memory + (index * this.slot_size)
            index = index + 1

        return null

    edit def release_bytes(slot: ptr[byte]?) -> bool:
        if slot == null:
            return false

        var index: usize = 0
        while index < this.slot_count:
            unsafe:
                let candidate = this.memory + (index * this.slot_size)
                if candidate == slot:
                    let state_ptr = this.occupancy + index
                    if *state_ptr == false:
                        return false

                    *state_ptr = false
                    this.used_count = this.used_count - 1
                    return true
            index = index + 1

        return false

    edit def release() -> void:
        unsafe:
            heap.release(cast[ptr[void]](this.memory))
            heap.release(cast[ptr[void]](this.occupancy))
        this.slot_size = 0
        this.slot_count = 0
        this.used_count = 0
        return
