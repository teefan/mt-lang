import std.mem.heap as heap


function slot_alignment(slot_size_bytes: ptr_uint, base_alignment: ptr_uint) -> ptr_uint:
    if slot_size_bytes == 0:
        return base_alignment

    var alignment = base_alignment
    while alignment > 1 and (slot_size_bytes & (alignment - 1)) != 0:
        alignment = alignment / 2

    return alignment

public struct Pool:
    memory: ptr[ubyte]?
    occupancy: ptr[bool]?
    ## Intrusive free-list: `free_head` is a slot index, `next_free[i]` is the
    ## next free slot after `i`, and `heap.ptr_uint_max` terminates the list.
    next_free: ptr[ptr_uint]?
    free_head: ptr_uint
    slot_size: ptr_uint
    slot_alignment: ptr_uint
    slot_count: ptr_uint
    used_count: ptr_uint


public function create(slot_size_bytes: ptr_uint, slot_count: ptr_uint) -> Pool:
    return create_aligned(slot_size_bytes, slot_count, 1)


public function create_aligned(slot_size_bytes: ptr_uint, slot_count: ptr_uint, alignment: ptr_uint) -> Pool:
    let normalized_alignment = heap.normalize_alignment(alignment)
    if normalized_alignment == 0:
        fatal(c"pool.create_aligned requires a power-of-two alignment")

    if slot_count == 0:
        return Pool(
            memory = null,
            occupancy = null,
            next_free = null,
            free_head = heap.ptr_uint_max,
            slot_size = slot_size_bytes,
            slot_alignment = slot_alignment(slot_size_bytes, normalized_alignment),
            slot_count = 0,
            used_count = 0
        )

    if slot_size_bytes == 0:
        fatal(c"pool.create_aligned requires slot size > 0 when slot count > 0")

    if heap.mul_overflows(slot_size_bytes, slot_count):
        fatal(c"pool.create size overflow")

    let total_size = slot_size_bytes * slot_count
    let memory = heap.alloc_bytes_aligned(total_size, normalized_alignment) else:
        fatal(c"pool.create_aligned out of memory")

    let occupancy = heap.alloc_zeroed[bool](slot_count) else:
        heap.release_bytes(memory)
        fatal(c"pool.create occupancy out of memory")

    let next_free = heap.alloc[ptr_uint](slot_count) else:
        heap.release(occupancy)
        heap.release_bytes(memory)
        fatal(c"pool.create free list out of memory")

    unsafe:
        var index: ptr_uint = 0
        while index < slot_count:
            read(next_free + index) = index + 1
            index += 1
        read(next_free + (slot_count - 1)) = heap.ptr_uint_max

    return unsafe: Pool(
            memory = ptr[ubyte]<-memory,
            occupancy = occupancy,
            next_free = next_free,
            free_head = 0,
            slot_size = slot_size_bytes,
            slot_alignment = slot_alignment(slot_size_bytes, normalized_alignment),
            slot_count = slot_count,
            used_count = 0
        )


public function slot_size_for[T]() -> ptr_uint:
    let size = ptr_uint<-size_of(T)
    let alignment = ptr_uint<-align_of(T)
    let mask = alignment - 1
    if size > heap.ptr_uint_max - mask:
        fatal(c"pool.slot_size_for overflow")

    return (size + mask) & ~mask


public function create_for[T](slot_count: ptr_uint) -> Pool:
    return create_aligned(slot_size_for[T](), slot_count, align_of(T))


extending Pool:
    public function remaining_slots() -> ptr_uint:
        return this.slot_count - this.used_count


    public editable function alloc_bytes() -> ptr[ubyte]?:
        if this.free_head == heap.ptr_uint_max:
            return null

        let memory = this.memory else:
            return null
        let occupancy = this.occupancy else:
            return null
        let next_free = this.next_free else:
            return null
        let index = this.free_head
        unsafe:
            this.free_head = read(next_free + index)
            read(occupancy + index) = true
            this.used_count = this.used_count + 1
            return memory + (index * this.slot_size)


    public editable function alloc[T]() -> ptr[T]?:
        let size = ptr_uint<-size_of(T)
        let alignment = ptr_uint<-align_of(T)
        let mask = alignment - 1
        if size > heap.ptr_uint_max - mask:
            return null

        let slot_size = (size + mask) & ~mask
        if this.slot_alignment < alignment:
            return null
        if this.slot_size < slot_size:
            return null

        let memory = this.alloc_bytes() else:
            return null

        return unsafe: ptr[T]<-memory


    public editable function release_bytes(slot: ptr[ubyte]?) -> bool:
        if slot == null:
            return false

        let memory = this.memory else:
            return false
        let occupancy = this.occupancy else:
            return false
        let next_free = this.next_free else:
            return false
        unsafe:
            let base = reinterpret[ptr_uint](memory)
            let target = reinterpret[ptr_uint](slot)
            if target < base:
                return false
            let offset = target - base
            if offset >= this.slot_size * this.slot_count:
                return false
            if offset % this.slot_size != 0:
                return false
            let index = offset / this.slot_size
            let state_ptr = occupancy + index
            if not read(state_ptr):
                return false
            read(state_ptr) = false
            read(next_free + index) = this.free_head
            this.free_head = index
            this.used_count = this.used_count - 1
            return true


    public editable function release_slot[T](slot: ptr[T]?) -> bool:
        if slot == null:
            return false

        return unsafe: this.release_bytes(ptr[ubyte]<-slot)


    public editable function release() -> void:
        heap.release(this.memory)
        heap.release(this.occupancy)
        heap.release(this.next_free)
        this.memory = null
        this.occupancy = null
        this.next_free = null
        this.free_head = heap.ptr_uint_max
        this.slot_size = 0
        this.slot_alignment = 0
        this.slot_count = 0
        this.used_count = 0
