module std.mem.heap

import std.c.libc as libc

pub def usize_max() -> usize:
    return ~usize<-0

pub def mul_overflows(left: usize, right: usize) -> bool:
    if left != 0 and right > usize_max() / left:
        return true

    return false

pub def alloc_bytes(size_bytes: usize) -> ptr[void]?:
    return libc.malloc(u64<-size_bytes)

pub def must_alloc_bytes(size_bytes: usize) -> ptr[void]:
    let memory = alloc_bytes(size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_bytes out of memory")

    unsafe:
        return ptr[void]<-memory

pub def alloc_zeroed_bytes(count: usize, element_size_bytes: usize) -> ptr[void]?:
    if mul_overflows(count, element_size_bytes):
        return null

    return libc.calloc(u64<-count, u64<-element_size_bytes)

pub def must_alloc_zeroed_bytes(count: usize, element_size_bytes: usize) -> ptr[void]:
    let memory = alloc_zeroed_bytes(count, element_size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_zeroed_bytes out of memory")

    unsafe:
        return ptr[void]<-memory

pub def resize_bytes(memory: ptr[void]?, size_bytes: usize) -> ptr[void]?:
    return libc.realloc(memory, u64<-size_bytes)

pub def must_resize_bytes(memory: ptr[void]?, size_bytes: usize) -> ptr[void]:
    let resized = resize_bytes(memory, size_bytes)
    if resized == null:
        panic(c"heap.must_resize_bytes out of memory")

    unsafe:
        return ptr[void]<-resized

pub def release_bytes(memory: ptr[void]?) -> void:
    libc.free(memory)
    return

pub def alloc[T](count: usize) -> ptr[T]?:
    let element_size = usize<-sizeof(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes(count * element_size)
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory

pub def must_alloc[T](count: usize) -> ptr[T]:
    let memory = alloc[T](count)
    if memory == null:
        panic(c"heap.must_alloc out of memory")

    unsafe:
        return ptr[T]<-memory

pub def alloc_zeroed[T](count: usize) -> ptr[T]?:
    let memory = alloc_zeroed_bytes(count, usize<-sizeof(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory

pub def must_alloc_zeroed[T](count: usize) -> ptr[T]:
    let memory = alloc_zeroed[T](count)
    if memory == null:
        panic(c"heap.must_alloc_zeroed out of memory")

    unsafe:
        return ptr[T]<-memory

pub def resize[T](memory: ptr[T]?, count: usize) -> ptr[T]?:
    let element_size = usize<-sizeof(T)
    if mul_overflows(count, element_size):
        return null

    if memory == null:
        let resized = resize_bytes(null, count * element_size)
        if resized == null:
            return null

        unsafe:
            return ptr[T]<-resized

    unsafe:
        let resized = resize_bytes(ptr[void]<-memory, count * element_size)
        if resized == null:
            return null

        return ptr[T]<-resized

pub def must_resize[T](memory: ptr[T]?, count: usize) -> ptr[T]:
    let resized = resize[T](memory, count)
    if resized == null:
        panic(c"heap.must_resize out of memory")

    unsafe:
        return ptr[T]<-resized

pub def release[T](memory: ptr[T]?) -> void:
    if memory == null:
        release_bytes(null)
        return

    unsafe:
        release_bytes(ptr[void]<-memory)
    return
