module std.mem.heap

import std.c.libc as libc

def alloc(size_bytes: usize) -> ptr[void]:
    return libc.malloc(cast[u64](size_bytes))

def alloc_zeroed(count: usize, element_size_bytes: usize) -> ptr[void]:
    return libc.calloc(cast[u64](count), cast[u64](element_size_bytes))

def resize(memory: ptr[void], size_bytes: usize) -> ptr[void]:
    return libc.realloc(memory, cast[u64](size_bytes))

def release(memory: ptr[void]) -> void:
    libc.free(memory)
    return
