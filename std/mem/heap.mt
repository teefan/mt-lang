module std.mem.heap

import std.c.libc as libc


def valid_alignment(alignment: ptr_uint) -> bool:
    if alignment == 0:
        return false

    return (alignment & (alignment - 1)) == 0


pub def ptr_uint_max() -> ptr_uint:
    return ~ptr_uint<-0


pub def minimum_alignment() -> ptr_uint:
    return ptr_uint<-size_of(ptr[void])


pub def normalize_alignment(alignment: ptr_uint) -> ptr_uint:
    if not valid_alignment(alignment):
        return 0

    let minimum = minimum_alignment()
    if alignment < minimum:
        return minimum

    return alignment


pub def mul_overflows(left: ptr_uint, right: ptr_uint) -> bool:
    if left != 0 and right > ptr_uint_max() / left:
        return true

    return false


pub def alloc_bytes(size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    return libc.malloc(ulong<-size_bytes)


pub def must_alloc_bytes(size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        panic(c"heap.must_alloc_bytes requires size > 0")

    let memory = alloc_bytes(size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_bytes out of memory")

    unsafe:
        return ptr[void]<-memory


pub def alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    let normalized_alignment = normalize_alignment(alignment)
    if normalized_alignment == 0:
        return null

    let mask = normalized_alignment - 1
    if size_bytes > ptr_uint_max() - mask:
        return null

    let rounded_size = (size_bytes + mask) & ~mask
    return libc.aligned_alloc(normalized_alignment, rounded_size)


pub def must_alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        panic(c"heap.must_alloc_bytes_aligned requires size > 0")

    let normalized_alignment = normalize_alignment(alignment)
    if normalized_alignment == 0:
        panic(c"heap.must_alloc_bytes_aligned requires a power-of-two alignment")

    let memory = alloc_bytes_aligned(size_bytes, normalized_alignment)
    if memory == null:
        panic(c"heap.must_alloc_bytes_aligned out of memory")

    unsafe:
        return ptr[void]<-memory


pub def alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]?:
    if count == 0 or element_size_bytes == 0:
        return null

    if mul_overflows(count, element_size_bytes):
        return null

    return libc.calloc(ulong<-count, ulong<-element_size_bytes)


pub def must_alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]:
    if count == 0 or element_size_bytes == 0:
        panic(c"heap.must_alloc_zeroed_bytes requires count > 0 and element size > 0")

    let memory = alloc_zeroed_bytes(count, element_size_bytes)
    if memory == null:
        panic(c"heap.must_alloc_zeroed_bytes out of memory")

    unsafe:
        return ptr[void]<-memory


pub def resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        release_bytes(memory)
        return null

    return libc.realloc(memory, ulong<-size_bytes)


pub def must_resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        panic(c"heap.must_resize_bytes requires size > 0")

    let resized = resize_bytes(memory, size_bytes)
    if resized == null:
        panic(c"heap.must_resize_bytes out of memory")

    unsafe:
        return ptr[void]<-resized


pub def release_bytes(memory: ptr[void]?) -> void:
    libc.free(memory)
    return


pub def alloc[T](count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment():
        return null

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes(count * element_size)
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory


pub def must_alloc[T](count: ptr_uint) -> ptr[T]:
    if ptr_uint<-align_of(T) > minimum_alignment():
        panic(c"heap.must_alloc does not support over-aligned types")

    let memory = alloc[T](count)
    if memory == null:
        panic(c"heap.must_alloc out of memory")

    unsafe:
        return ptr[T]<-memory


pub def alloc_aligned[T](count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes_aligned(count * element_size, ptr_uint<-align_of(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory


pub def must_alloc_aligned[T](count: ptr_uint) -> ptr[T]:
    let memory = alloc_aligned[T](count)
    if memory == null:
        panic(c"heap.must_alloc_aligned out of memory")

    unsafe:
        return ptr[T]<-memory


pub def alloc_zeroed[T](count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment():
        return null

    let memory = alloc_zeroed_bytes(count, ptr_uint<-size_of(T))
    if memory == null:
        return null

    unsafe:
        return ptr[T]<-memory


pub def must_alloc_zeroed[T](count: ptr_uint) -> ptr[T]:
    if ptr_uint<-align_of(T) > minimum_alignment():
        panic(c"heap.must_alloc_zeroed does not support over-aligned types")

    let memory = alloc_zeroed[T](count)
    if memory == null:
        panic(c"heap.must_alloc_zeroed out of memory")

    unsafe:
        return ptr[T]<-memory


pub def resize[T](memory: ptr[T]?, count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment():
        return null

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
    if ptr_uint<-align_of(T) > minimum_alignment():
        panic(c"heap.must_resize does not support over-aligned types")

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
