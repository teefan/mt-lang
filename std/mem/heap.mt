import std.c.libc as libc
import std.cstring as cstring

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


# ── Regions ─────────────────────────────────────────────────────────────────
#
# A region is a growable bump allocator.  While a region is active, the heap's
# allocation functions serve requests from it; releasing region memory is a
# no-op and the memory is freed in one step by `Region.release_all()`.  The
# LSP's module cache owns one region per parsed module version and releases it
# when a superseded entry is replaced.  CLI runs never activate a region and
# keep the plain libc path.

public const region_header_bytes: ptr_uint = 16
public const region_min_block_bytes: ptr_uint = 16384
public const region_max_alignment: ptr_uint = 16


public struct RegionBlock:
    data: ptr[ubyte]?
    capacity: ptr_uint
    used: ptr_uint


## A growable bump region.  Blocks are allocated with libc directly (region
## bookkeeping must never be captured by another active region), and every
## allocation is preceded by a 16-byte header holding its size.
public struct Region:
    blocks: ptr[RegionBlock]?
    block_count: ptr_uint
    block_capacity: ptr_uint
    next_block_bytes: ptr_uint


var active_region: ptr[Region]? = null


public function create_region() -> Region:
    return Region(blocks = null, block_count = 0, block_capacity = 0, next_block_bytes = 0)


## Make `region` the active allocation region and return the previous one.
## Pass the result to `end_region` to restore it (regions nest).
public function begin_region(region: ptr[Region]) -> ptr[Region]?:
    let previous = active_region
    active_region = region
    return previous


public function end_region(previous: ptr[Region]?) -> void:
    active_region = previous


extending Region:
    ## Whether `address` points into one of the region's blocks.
    public function contains(address: ptr[void]?) -> bool:
        if address == null:
            return false
        let blocks = this.blocks else:
            return false
        unsafe:
            let target = reinterpret[ptr_uint](address)
            var i: ptr_uint = 0
            while i < this.block_count:
                let block = read(blocks + i)
                let data = block.data else:
                    i += 1
                    continue
                let start = reinterpret[ptr_uint](data)
                if target >= start and target < start + block.used:
                    return true
                i += 1
        return false


    ## Ensure the last block has room for one allocation and return the block
    ## list; grows the metadata array and/or appends a block as needed.  Null on
    ## out-of-memory.
    public editable function reserve_block(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[RegionBlock]?:
        if this.block_count > 0:
            let blocks = this.blocks else:
                return null
            var last: RegionBlock
            unsafe:
                last = read(blocks + (this.block_count - 1))
            var offset = last.used + region_header_bytes
            offset = (offset + alignment - 1) & ~(alignment - 1)
            if offset + size_bytes <= last.capacity:
                return blocks

        var capacity = this.next_block_bytes
        let needed = size_bytes + region_header_bytes + alignment
        if capacity < needed:
            capacity = needed
        if capacity < region_min_block_bytes:
            capacity = region_min_block_bytes

        let memory = libc.malloc(capacity) else:
            return null
        if this.block_count == this.block_capacity:
            var next_capacity = this.block_capacity * 2
            if next_capacity < 4:
                next_capacity = 4
            unsafe:
                let grown = libc.realloc(ptr[void]<-this.blocks, next_capacity * size_of(RegionBlock)) else:
                    libc.free(memory)
                    return null
                this.blocks = ptr[RegionBlock]<-grown
                this.block_capacity = next_capacity
        let blocks = this.blocks else:
            libc.free(memory)
            return null
        unsafe:
            read(blocks + this.block_count) = RegionBlock(
                data = ptr[ubyte]<-memory,
                capacity = capacity,
                used = 0
            )
        this.block_count += 1
        if capacity > ptr_uint_max / 2: this.next_block_bytes = capacity else: this.next_block_bytes = capacity * 2
        return blocks


    ## Bump-allocate `size_bytes` aligned to `alignment` (a power of two up to
    ## `region_max_alignment`).  Null for a zero size, an unsupported alignment
    ## or out-of-memory.
    public editable function alloc_aligned_bytes(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[ubyte]?:
        if size_bytes == 0:
            return null
        if alignment == 0:
            return null
        if (alignment & (alignment - 1)) != 0:
            return null
        if alignment > region_max_alignment:
            return null

        let blocks = this.reserve_block(size_bytes, alignment) else:
            return null
        unsafe:
            let block_ptr = blocks + (this.block_count - 1)
            var offset = read(block_ptr).used + region_header_bytes
            offset = (offset + alignment - 1) & ~(alignment - 1)
            let data = read(block_ptr).data else:
                return null
            let payload = data + offset
            let header = ptr[ptr_uint]<-payload
            read(header - 2) = size_bytes
            read(header - 1) = 0
            read(block_ptr).used = offset + size_bytes
            return payload


    ## Resize a region-owned allocation: shrink updates the header in place;
    ## grow allocates a new payload and copies (the old payload stays abandoned
    ## in its block, like every bump allocation).
    public editable function resize_payload(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]?:
        if memory == null or size_bytes == 0:
            return null
        unsafe:
            let source = ptr[ubyte]<-memory
            let header = ptr[ptr_uint]<-source
            let old_size = read(header - 2)
            if size_bytes <= old_size:
                read(header - 2) = size_bytes
                return memory
            let grown = this.alloc_aligned_bytes(size_bytes, minimum_alignment) else:
                return null
            cstring.copy_bytes(ptr[void]<-grown, ptr[void]<-source, old_size)
            return ptr[void]<-grown


    ## Free every block and reset the region.  Only this call frees region
    ## memory; `heap.release_bytes` on region memory is a no-op.
    public editable function release_all() -> void:
        let blocks = this.blocks else:
            return
        var i: ptr_uint = 0
        while i < this.block_count:
            unsafe:
                let data = read(blocks + i).data
                if data != null:
                    libc.free(ptr[void]<-data)
            i += 1
        unsafe:
            libc.free(ptr[void]<-blocks)
        this.blocks = null
        this.block_count = 0
        this.block_capacity = 0
        this.next_block_bytes = 0


public function alloc_bytes(size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    let region = active_region
    if region != null:
        unsafe:
            let memory = read(region).alloc_aligned_bytes(size_bytes, minimum_alignment) else:
                return null
            return ptr[void]<-memory

    return libc.malloc(size_bytes)


public function must_alloc_bytes(size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        fatal(c"heap.must_alloc_bytes requires size > 0")

    let memory = alloc_bytes(size_bytes) else:
        fatal(c"heap.must_alloc_bytes out of memory")

    return memory


public function alloc_bytes_aligned(size_bytes: ptr_uint, alignment: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    let normalized_alignment = normalize_alignment(alignment)
    if normalized_alignment == 0:
        return null

    let region = active_region
    if region != null and normalized_alignment <= region_max_alignment:
        unsafe:
            let memory = read(region).alloc_aligned_bytes(size_bytes, normalized_alignment) else:
                return null
            return ptr[void]<-memory

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

    return memory


public function alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]?:
    if count == 0 or element_size_bytes == 0:
        return null

    if mul_overflows(count, element_size_bytes):
        return null

    let region = active_region
    if region != null:
        unsafe:
            let memory = read(region).alloc_aligned_bytes(count * element_size_bytes, minimum_alignment) else:
                return null
            cstring.set_bytes(ptr[void]<-memory, 0, count * element_size_bytes)
            return ptr[void]<-memory

    return libc.calloc(count, element_size_bytes)


public function must_alloc_zeroed_bytes(count: ptr_uint, element_size_bytes: ptr_uint) -> ptr[void]:
    if count == 0 or element_size_bytes == 0:
        fatal(c"heap.must_alloc_zeroed_bytes requires count > 0 and element size > 0")

    let memory = alloc_zeroed_bytes(count, element_size_bytes) else:
        fatal(c"heap.must_alloc_zeroed_bytes out of memory")

    return memory


public function copy_bytes(destination: ptr[ubyte]?, source: ptr[ubyte]?, size_bytes: ptr_uint) -> void:
    if size_bytes == 0:
        return

    if destination == null or source == null:
        fatal(c"heap.copy_bytes requires non-null pointers for non-empty copies")

    unsafe:
        cstring.copy_bytes(ptr[void]<-destination, ptr[void]<-source, size_bytes)


public function move_bytes(destination: ptr[ubyte]?, source: ptr[ubyte]?, size_bytes: ptr_uint) -> void:
    if size_bytes == 0:
        return

    if destination == null or source == null:
        fatal(c"heap.move_bytes requires non-null pointers for non-empty copies")

    unsafe:
        cstring.move_bytes(ptr[void]<-destination, ptr[void]<-source, size_bytes)


public function resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        release_bytes(memory)
        return null

    let region = active_region
    if region != null:
        if memory == null:
            return alloc_bytes(size_bytes)
        unsafe:
            if read(region).contains(memory):
                return read(region).resize_payload(memory, size_bytes)

    return libc.realloc(memory, size_bytes)


public function must_resize_bytes(memory: ptr[void]?, size_bytes: ptr_uint) -> ptr[void]:
    if size_bytes == 0:
        fatal(c"heap.must_resize_bytes requires size > 0")

    let resized = resize_bytes(memory, size_bytes) else:
        fatal(c"heap.must_resize_bytes out of memory")

    return resized


## Frees a raw memory allocation. The caller's binding is NOT nulled after
## this call — a second `release_bytes` on the same pointer is a double-free.
## This is inherent to by-value pointer parameters: the function cannot reach
## the caller's binding to null it. For idempotent safe-release syntax, see
## `release_and_null[T]` or use a scope-bound allocator such as `arena.Arena`.
## Memory owned by the active region is a no-op here: a region frees its
## allocations only through `Region.release_all()`.
public function release_bytes(memory: ptr[void]?) -> void:
    if memory == null:
        return

    let region = active_region
    if region != null:
        unsafe:
            if read(region).contains(memory):
                return

    libc.free(memory)


public function alloc[T](count: ptr_uint) -> own[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes(count * element_size) else:
        return null

    return unsafe: own[T]<-memory


public function must_alloc[T](count: ptr_uint) -> own[T]:
    if count == 0:
        fatal(c"heap.must_alloc requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_alloc does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc size overflow")

    let memory = alloc[T](count) else:
        fatal(c"heap.must_alloc out of memory")

    return memory


public function alloc_aligned[T](count: ptr_uint) -> own[T]?:
    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    let memory = alloc_bytes_aligned(count * element_size, align_of(T)) else:
        return null

    return unsafe: own[T]<-memory


public function must_alloc_aligned[T](count: ptr_uint) -> own[T]:
    if count == 0:
        fatal(c"heap.must_alloc_aligned requires count > 0")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc_aligned size overflow")

    let memory = alloc_aligned[T](count) else:
        fatal(c"heap.must_alloc_aligned out of memory")

    return memory


public function alloc_zeroed[T](count: ptr_uint) -> own[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let memory = alloc_zeroed_bytes(count, size_of(T)) else:
        return null

    return unsafe: own[T]<-memory


public function must_alloc_zeroed[T](count: ptr_uint) -> own[T]:
    if count == 0:
        fatal(c"heap.must_alloc_zeroed requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_alloc_zeroed does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_alloc_zeroed size overflow")

    let memory = alloc_zeroed[T](count) else:
        fatal(c"heap.must_alloc_zeroed out of memory")

    return memory


public function resize[T](memory: ptr[T]?, count: ptr_uint) -> own[T]?:
    let alignment = ptr_uint<-align_of(T)
    if alignment > minimum_alignment:
        return null

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        return null

    if memory == null:
        let resized = resize_bytes(null, count * element_size) else:
            return null

        return unsafe: own[T]<-resized

    unsafe:
        let resized = resize_bytes(ptr[void]<-memory, count * element_size) else:
            return null

        return own[T]<-resized


public function must_resize[T](memory: ptr[T]?, count: ptr_uint) -> own[T]:
    if count == 0:
        fatal(c"heap.must_resize requires count > 0")

    if ptr_uint<-align_of(T) > minimum_alignment:
        fatal(c"heap.must_resize does not support over-aligned types")

    let element_size = ptr_uint<-size_of(T)
    if mul_overflows(count, element_size):
        fatal(c"heap.must_resize size overflow")

    let resized = resize[T](memory, count) else:
        fatal(c"heap.must_resize out of memory")

    return resized


## Frees a typed heap allocation. The caller's binding is NOT nulled — a
## second `release` on the same pointer is a double-free. Prefer
## `release_and_null[T]` when you need the binding nulled after freeing,
## or use a scope-bound allocator such as `arena.Arena` for bulk free.
public function release[T](memory: ptr[T]?) -> void:
    unsafe: release_bytes(ptr[void]<-memory)


## Frees a typed heap allocation and nulls the caller's binding so a second
## release is a no-op. The binding is passed by `ref[ptr[T]?]` so the helper
## can write `null` back into the caller's variable.
##
##     var mem = heap.must_alloc[MyStruct](1)
##     heap.release_and_null(ref_of(mem))       # mem is now null
##     heap.release_and_null(ref_of(mem))       # safe — no-op
public function release_and_null[T](memory: ref[ptr[T]?]) -> void:
    unsafe: release_bytes(ptr[void]<-read(memory))
    read(memory) = null


public function bytes_of[T](value: ref[T]) -> span[ubyte]:
    unsafe:
        return span[ubyte](data = ptr[ubyte]<-ptr_of(value), len = size_of(T))
