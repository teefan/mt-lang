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

impl Arena:
    def mark(self) -> Mark:
        return self.offset

    def reset(mut self, mark: Mark) -> void:
        self.offset = mark
        return

    def remaining_bytes(self) -> usize:
        return self.capacity - self.offset

    def alloc_bytes(mut self, size_bytes: usize) -> ptr[byte]?:
        let next_offset = self.offset + size_bytes
        if next_offset > self.capacity:
            return null

        unsafe:
            let result = self.memory + self.offset
            self.offset = next_offset
            return result

    def release(mut self) -> void:
        unsafe:
            heap.release(cast[ptr[void]](self.memory))
        self.offset = 0
        self.capacity = 0
        return
