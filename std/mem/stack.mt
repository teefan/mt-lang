module std.mem.stack

import std.mem.arena as arena

type Mark = arena.Mark

struct Stack:
    arena: arena.Arena

def create(capacity_bytes: usize) -> Stack:
    return Stack(arena = arena.create(capacity_bytes))

impl Stack:
    def mark(self) -> Mark:
        return self.arena.mark()

    def reset(mut self, mark: Mark) -> void:
        self.arena.reset(mark)
        return

    def remaining_bytes(self) -> usize:
        return self.arena.remaining_bytes()

    def alloc_bytes(mut self, size_bytes: usize) -> ptr[byte]?:
        return self.arena.alloc_bytes(size_bytes)

    def release(mut self) -> void:
        self.arena.release()
        return
