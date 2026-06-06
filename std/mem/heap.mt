import std.c.libc as libc

public const ptr_uint_max: ptr_uint = ~0
public const minimum_alignment: ptr_uint = size_of(ptr[void])


function valid_alignment(alignment: ptr_uint) -> bool:
    if alignment == 0:
        return false

    return (alignment & (alignment - 1)) == 0


public function normalize_alignment(alignment: ptr_uint) -> ptr_uint:
    if not valid_alignment(alignment):
        return 0

    let minimum = minimum_alignment
    if alignment < minimum:
        return minimum

    return alignment


public function mul_overflows(left: ptr_uint, right: ptr_uint) -> bool:
    if left != 0 and right > ptr_uint_max / left:
        return true

    return false


public function alloc_bytes(size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    return libc.malloc(size_bytes)


public function must_alloc_bytes(size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        fatal(c"heap.must_alloc_bytes requires size > 0")

    let memory = alloc_bytes(size_bytes) else:
        fatal(c"heap.must_alloc_bytes out of memory")

    return ptr[void]<-memory


public function alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    let normalized_alignment = normalize_alignment(alignment)
    if normalized_alignment == 0:
        return null

    let mask = normalized_alignment - 1
    if size_bytes > ptr_uint_max - mask:
        return null

    let rounded_size = (size_bytes + mask) & ~mask
    return libc.aligned_alloc(normalized_alignment, rounded_size)


public function must_alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        fatal(c"heap.must_alloc_bytes_aligned requires size > 0")

    let normalized_alignment = normalize_alignment(alignment)
    if normalized_alignment == 0:
        fatal(c"heap.must_alloc_bytes_aligned requires a power-of-two alignment")

    let memory = alloc_bytes_aligned(size_bytes, normalized_alignment) else:
        fatal(c"heap.must_alloc_bytes_aligned out of memory")

    return ptr[void]<-memory


public function alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]?:
    if count == 0 or element_size_bytes == 0:
        return null

    if mul_overflows(count, element_size_bytes):
        return null

    return libc.calloc(count, element_size_bytes)


public function must_alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]:
    if count == 0 or element_size_bytes == 0:
        fatal(c"heap.must_alloc_zeroed_bytes requires count > 0 and element size > 0")

    let memory = alloc_zeroed_bytes(count, element_size_bytes) else:
        fatal(c"heap.must_alloc_zeroed_bytes out of memory")

    return ptr[void]<-memory


public function copy_bytes(destination: ptr[ubyte]?, source: ptr[ubyte]?, size_bytes: ptr_uint) -> void:
    if size_bytes == 0:
        return

    if destination == null or source == null:
        fatal(c"heap.copy_bytes requires non-null pointers for non-empty copies")

    var index: ptr_uint = 0
    while index < size_bytes:
        unsafe:
            read(ptr[ubyte]<-destination + index) = read(ptr[ubyte]<-source + index)
        index += 1


public function resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        release_bytes(memory)
        return null

    return libc.realloc(memory, size_bytes)


public function must_resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        fatal(c"heap.must_resize_bytes requires size > 0")

    let resized = resize_bytes(memory, size_bytes) else:
        fatal(c"heap.must_resize_bytes out of memory")

    return ptr[void]<-resized


public function release_bytes(memory: ptr[void]?) -> void:
    libc.free(memory)


public function alloc[T](count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes(count * element_size) else:
        return null

    return unsafe: ptr[T]<-memory


public function must_alloc[T](count: ptr_uint) -> ptr[T]:
    if count == 0:
        fatal(c"heap.must_alloc requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_alloc does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc size overflow")

    let memory = alloc[T](count) else:
        fatal(c"heap.must_alloc out of memory")

    return unsafe: ptr[T]<-memory


public function alloc_aligned[T](count: ptr_uint) -> ptr[T]?:
    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes_aligned(count * element_size, align_of(T)) else:
        return null

    return unsafe: ptr[T]<-memory


public function must_alloc_aligned[T](count: ptr_uint) -> ptr[T]:
    if count == 0:
        fatal(c"heap.must_alloc_aligned requires count > 0")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc_aligned size overflow")

    let memory = alloc_aligned[T](count) else:
        fatal(c"heap.must_alloc_aligned out of memory")

    return unsafe: ptr[T]<-memory


public function alloc_zeroed[T](count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let memory = alloc_zeroed_bytes(count, size_of(T)) else:
        return null

    return unsafe: ptr[T]<-memory


public function must_alloc_zeroed[T](count: ptr_uint) -> ptr[T]:
    if count == 0:
        fatal(c"heap.must_alloc_zeroed requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_alloc_zeroed does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc_zeroed size overflow")

    let memory = alloc_zeroed[T](count) else:
        fatal(c"heap.must_alloc_zeroed out of memory")

    return unsafe: ptr[T]<-memory


public function resize[T](memory: ptr[T]?, count: ptr_uint) -> ptr[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    if memory == null:
        let resized = resize_bytes(null, count * element_size) else:
            return null

        return unsafe: ptr[T]<-resized

    unsafe:
        let resized = resize_bytes(ptr[void]<-memory, count * element_size) else:
            return null

        return ptr[T]<-resized


public function must_resize[T](memory: ptr[T]?, count: ptr_uint) -> ptr[T]:
    if count == 0:
        fatal(c"heap.must_resize requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_resize does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_resize size overflow")

    let resized = resize[T](memory, count) else:
        fatal(c"heap.must_resize out of memory")

    return unsafe: ptr[T]<-resized


public function release[T](memory: ptr[T]?) -> void:
    unsafe: release_bytes(ptr[void]<-memory)
