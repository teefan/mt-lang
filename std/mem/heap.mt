module std.mem.heap

import std.c.libc as libc


pub def ptr_uint_max() -> ptr_uint:
    return ~ptr_uint<-0


pub def mul_overflows(left: ptr_uint, right: ptr_uint) -> bool:
    if left != 0 and right > ptr_uint_max() / left:
        return true

    return false


pub def alloc_bytes(size_bytes: ptr_uint) -> ptr[void]?:
    return libc.malloc(ulong<-size_bytes)


pub def must_alloc_bytes(size_bytes: ptr_uint) -> ptr[void]:
    let memory = alloc_bytes(size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_bytes out of memory")

    unsafe:
        return ptr[void]<-memory


pub def alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]?:
    if mul_overflows(count, element_size_bytes):
        return null

    return libc.calloc(ulong<-count, ulong<-element_size_bytes)


pub def must_alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]:
    let memory = alloc_zeroed_bytes(count, element_size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_zeroed_bytes out of memory")

    unsafe:
        return ptr[void]<-memory


pub def resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]?:
    return libc.realloc(memory, ulong<-size_bytes)


pub def must_resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]:
    let resized = resize_bytes(memory, size_bytes)
    if resized == null:
        panic(c"heap.must_resize_bytes out of memory")

    unsafe:
        return ptr[void]<-resized


pub def release_bytes(memory: ptr[void]?) -> void:
    libc.free(memory)
    return


pub def alloc[T](count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes(count * element_size)
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory


pub def must_alloc[T](count: ptr_uint) -> ptr[T]:
    let memory = alloc[T](count)
    if memory == null:
        panic(c"heap.must_alloc out of memory")

    unsafe:
        return ptr[T]<-memory


pub def alloc_zeroed[T](count: ptr_uint) -> ptr[T]?:
    let memory = alloc_zeroed_bytes(count, ptr_uint<-size_of(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory


pub def must_alloc_zeroed[T](count: ptr_uint) -> ptr[T]:
    let memory = alloc_zeroed[T](count)
    if memory == null:
        panic(c"heap.must_alloc_zeroed out of memory")

    unsafe:
        return ptr[T]<-memory


pub def resize[T](memory: ptr[T]?, count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
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


pub def must_resize[T](memory: ptr[T]?, count: ptr_uint) -> ptr[T]:
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
