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

impl Pool:
    def remaining_slots(self) -> usize:
        return self.slot_count - self.used_count

    def alloc_bytes(mut self) -> ptr[byte]?:
        var index: usize = 0
        while index < self.slot_count:
            unsafe:
                let state_ptr = self.occupancy + index
                if *state_ptr == false:
                    *state_ptr = true
                    self.used_count = self.used_count + 1
                    return self.memory + (index * self.slot_size)
            index = index + 1

        return null

    def release_bytes(mut self, slot: ptr[byte]?) -> bool:
        if slot == null:
            return false

        var index: usize = 0
        while index < self.slot_count:
            unsafe:
                let candidate = self.memory + (index * self.slot_size)
                if candidate == slot:
                    let state_ptr = self.occupancy + index
                    if *state_ptr == false:
                        return false

                    *state_ptr = false
                    self.used_count = self.used_count - 1
                    return true
            index = index + 1

        return false

    def release(mut self) -> void:
        unsafe:
            heap.release(cast[ptr[void]](self.memory))
            heap.release(cast[ptr[void]](self.occupancy))
        self.slot_size = 0
        self.slot_count = 0
        self.used_count = 0
        return
