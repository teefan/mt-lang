import std.c.heap as heap_c
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
##
## The active region and the live-region list are thread-local.  A region is
## owned by the thread that created it; `begin_region`/`end_region` also scope
## its registration in the live list, so a region copied into a cache entry
## after `end_region` never carries stale list pointers.
public struct Region:
    blocks: ptr[RegionBlock]?
    block_count: ptr_uint
    block_capacity: ptr_uint
    next_block_bytes: ptr_uint
    owner_thread: ptr_uint
    registered: bool
    prev_live: ptr[Region]?
    next_live: ptr[Region]?


public function create_region() -> Region:
    return Region(
        blocks = null,
        block_count = 0,
        block_capacity = 0,
        next_block_bytes = 0,
        owner_thread = heap_c.mt_thread_id(),
        registered = false,
        prev_live = null,
        next_live = null
    )


function set_active_region(region: ptr[Region]?) -> void:
    if region == null:
        heap_c.mt_heap_set_active_region(null)
    else:
        unsafe:
            heap_c.mt_heap_set_active_region(ptr[void]<-region)


function set_live_region_head(region: ptr[Region]?) -> void:
    if region == null:
        heap_c.mt_heap_set_live_regions(null)
    else:
        unsafe:
            heap_c.mt_heap_set_live_regions(ptr[void]<-region)


## The active region for this thread, checking that it belongs to this thread.
function current_region() -> ptr[Region]?:
    let raw = heap_c.mt_heap_get_active_region()
    if raw == null:
        return null
    unsafe:
        let region = ptr[Region]<-raw
        let owner = read(region).owner_thread
        let current = heap_c.mt_thread_id()
        if owner != 0 and owner != current:
            fatal(c"heap: active region belongs to another thread")
        return region


function register_live_region(region: ptr[Region]) -> void:
    let head_raw = heap_c.mt_heap_get_live_regions()
    var head: ptr[Region]? = null
    if head_raw != null:
        unsafe:
            head = ptr[Region]<-head_raw
    unsafe:
        read(region).prev_live = null
        read(region).next_live = head
        if head != null:
            read(head).prev_live = region
        read(region).registered = true
    set_live_region_head(region)


function unregister_live_region(region: ptr[Region]) -> void:
    unsafe:
        let prev = read(region).prev_live
        let next = read(region).next_live
        if prev != null:
            read(prev).next_live = next
        else:
            set_live_region_head(next)
        if next != null:
            read(next).prev_live = prev
        read(region).prev_live = null
        read(region).next_live = null
        read(region).registered = false


## True when `memory` belongs to any live region registered on this thread.
## Used on the slow release/resize path to reject a pointer whose region is not
## the active one instead of handing interior region memory to libc.
function belongs_to_live_region(memory: ptr[void]?) -> bool:
    if memory == null:
        return false
    let head_raw = heap_c.mt_heap_get_live_regions()
    if head_raw == null:
        return false
    unsafe:
        var region: ptr[Region]? = ptr[Region]<-head_raw
        while region != null:
            if read(region).contains(memory):
                return true
            region = read(region).next_live
    return false


## Make `region` the active allocation region for this thread and return the
## previous one.  The region is registered in the thread-local live list so a
## release from the wrong region can be diagnosed.
public function begin_region(region: ptr[Region]) -> ptr[Region]?:
    var owner: ptr_uint = 0
    var registered = false
    unsafe:
        owner = read(region).owner_thread
        registered = read(region).registered
    let current = heap_c.mt_thread_id()
    if owner != 0 and owner != current:
        fatal(c"heap.begin_region: region belongs to another thread")
    if owner == 0:
        unsafe:
            read(region).owner_thread = current
    if not registered:
        register_live_region(region)
    let previous = current_region()
    set_active_region(region)
    return previous


public function end_region(previous: ptr[Region]?) -> void:
    let current = current_region()
    if current != null:
        var registered = false
        unsafe:
            registered = read(current).registered
        if registered:
            unregister_live_region(current)
    if previous != null:
        var owner: ptr_uint = 0
        unsafe:
            owner = read(previous).owner_thread
        let current_thread = heap_c.mt_thread_id()
        if owner != 0 and owner != current_thread:
            fatal(c"heap.end_region: previous region belongs to another thread")
    set_active_region(previous)


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
    ## grow extends in place when the payload is the block's most recent
    ## allocation and the block still has room, otherwise it allocates a new
    ## payload and copies (the old payload stays abandoned in its block, like
    ## every bump allocation).
    ##
    ## In-place growth is what keeps a region from inflating the peak: a vector
    ## that doubles repeatedly (`Vec.reserve`, `String.reserve`) would otherwise
    ## abandon ~2x its final size in dead copies.  The extension is safe because
    ## bump allocation only ever hands out the tail of the block, so the bytes
    ## after the payload are unallocated.
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
            let grown = grow_payload_in_place(this, memory, old_size, size_bytes) else:
                let moved = this.alloc_aligned_bytes(size_bytes, minimum_alignment) else:
                    return null
                cstring.copy_bytes(ptr[void]<-moved, ptr[void]<-source, old_size)
                return ptr[void]<-moved
            return grown


    ## Free every block and reset the region.  Only this call frees region
    ## memory; `heap.release_bytes` on region memory is a no-op.
    public editable function release_all() -> void:
        if this.registered:
            fatal(c"heap.Region.release_all called inside its begin_region/end_region scope")
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


## Extend the most recent allocation in the region's current block from
## `old_size` to `size_bytes` in place, or null when it is not that allocation
## or the block cannot hold the larger payload.  Only the block's tail is
## unallocated, so a payload ending exactly at `used` may claim the bytes after
## it; anything else must move.
function grow_payload_in_place(region: ref[Region], memory: ptr[void]?, old_size: ptr_uint, size_bytes: ptr_uint) -> ptr[void]?:
    if region.block_count == 0:
        return null
    let blocks = region.blocks else:
        return null
    unsafe:
        let block_ptr = blocks + (region.block_count - 1)
        let data = read(block_ptr).data else:
            return null
        let target = ptr[ubyte]<-memory
        let offset = reinterpret[ptr_uint](target) - reinterpret[ptr_uint](data)
        if read(block_ptr).used != offset + old_size:
            return null
        let needed = offset + size_bytes
        if needed > read(block_ptr).capacity:
            return null
        read(block_ptr).used = needed
        read(ptr[ptr_uint]<-target - 2) = size_bytes
        return memory


public function alloc_bytes(size_bytes: ptr_uint) -> ptr[void]?:
    if size_bytes == 0:
        return null

    let region = current_region()
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

    let region = current_region()
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

    let region = current_region()
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

    let region = current_region()
    if region != null:
        if memory == null:
            return alloc_bytes(size_bytes)
        unsafe:
            if read(region).contains(memory):
                return read(region).resize_payload(memory, size_bytes)

    if belongs_to_live_region(memory):
        fatal(c"heap.resize_bytes: pointer belongs to a live region that is not active; resize it inside that region's scope")

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
## Memory owned by any live region on this thread is a no-op here: a region
## frees its allocations only through `Region.release_all()`, even when a
## different region is active.
public function release_bytes(memory: ptr[void]?) -> void:
    if memory == null:
        return

    let region = current_region()
    if region != null:
        unsafe:
            if read(region).contains(memory):
                return

    if belongs_to_live_region(memory):
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
