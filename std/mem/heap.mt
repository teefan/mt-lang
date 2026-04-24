module std.mem.heap

import std.c.libc as libc

pub def alloc_bytes(size_bytes: usize) -> ptr[void]:
    return libc.malloc(cast[u64](size_bytes))

pub def alloc_zeroed_bytes(count: usize, element_size_bytes: usize) -> ptr[void]:
    return libc.calloc(cast[u64](count), cast[u64](element_size_bytes))

pub def resize_bytes(memory: ptr[void], size_bytes: usize) -> ptr[void]:
    return libc.realloc(memory, cast[u64](size_bytes))

pub def release_bytes(memory: ptr[void]) -> void:
    libc.free(memory)
    return

pub def alloc[T](count: usize) -> ptr[T]:
    unsafe:
        return cast[ptr[T]](alloc_bytes(count * cast[usize](sizeof(T))))

pub def alloc_zeroed[T](count: usize) -> ptr[T]:
    unsafe:
        return cast[ptr[T]](alloc_zeroed_bytes(count, cast[usize](sizeof(T))))

pub def resize[T](memory: ptr[T], count: usize) -> ptr[T]:
    unsafe:
        return cast[ptr[T]](resize_bytes(cast[ptr[void]](memory), count * cast[usize](sizeof(T))))

pub def release[T](memory: ptr[T]) -> void:
    unsafe:
        release_bytes(cast[ptr[void]](memory))
    return
