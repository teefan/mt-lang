module std.map

import std.mem.heap as heap

const empty_state: ubyte = 0
const full_state: ubyte = 1
const tombstone_state: ubyte = 2

public struct Entry[K, V]:
    key: K
    value: V
    hash: ulong
    state: ubyte

public struct HashMap[K, V]:
    entries: ptr[Entry[K, V]]?
    len: ptr_uint
    capacity: ptr_uint
    hash_fn: fn(key: K) -> ulong
    equals_fn: fn(left: K, right: K) -> bool


public function create[K, V](hash_fn: fn(key: K) -> ulong, equals_fn: fn(left: K, right: K) -> bool) -> HashMap[K, V]:
    return HashMap[K, V](
        entries = null,
        len = 0,
        capacity = 0,
        hash_fn = hash_fn,
        equals_fn = equals_fn,
    )


public function count[K, V](items: HashMap[K, V]) -> ptr_uint:
    return items.len


public function capacity[K, V](items: HashMap[K, V]) -> ptr_uint:
    return items.capacity


public function release[K, V](items: ref[HashMap[K, V]]) -> void:
    heap.release(items.entries)
    items.entries = null
    items.len = 0
    items.capacity = 0
    return


function index_for(hash: ulong, capacity: ptr_uint) -> ptr_uint:
    return ptr_uint<-(hash % ulong<-capacity)


function should_grow(len: ptr_uint, capacity: ptr_uint) -> bool:
    if capacity == 0:
        return true
    return (len + 1) * 4 >= capacity * 3


function insert_existing[K, V](entries: ptr[Entry[K, V]], capacity: ptr_uint, entry: Entry[K, V]) -> void:
    var index = index_for(entry.hash, capacity)
    var probes: ptr_uint = 0
    while probes < capacity:
        unsafe:
            let slot = entries + index
            if slot.state != full_state:
                read(slot) = entry
                return
        index = (index + 1) % capacity
        probes += 1

    panic(c"map.insert_existing table full")


public function try_reserve[K, V](items: ref[HashMap[K, V]], min_capacity: ptr_uint) -> bool:
    if min_capacity <= items.capacity:
        return true

    var new_capacity = items.capacity
    if new_capacity == 0:
        new_capacity = 8
    while new_capacity < min_capacity:
        if new_capacity > heap.ptr_uint_max() / 2:
            new_capacity = min_capacity
        else:
            new_capacity *= 2

    let new_entries = heap.alloc_zeroed[Entry[K, V]](new_capacity)
    if new_entries == null:
        return false

    let old_entries = items.entries
    if old_entries != null:
        var index: ptr_uint = 0
        while index < items.capacity:
            unsafe:
                let entry = read(old_entries + index)
                if entry.state == full_state:
                    insert_existing[K, V](new_entries, new_capacity, entry)
            index += 1
        heap.release(old_entries)

    items.entries = new_entries
    items.capacity = new_capacity
    return true


public function reserve[K, V](items: ref[HashMap[K, V]], min_capacity: ptr_uint) -> void:
    if not try_reserve[K, V](items, min_capacity):
        panic(c"map.reserve out of memory")
    return


public function try_put[K, V](items: ref[HashMap[K, V]], key: K, value_item: V) -> bool:
    if should_grow(items.len, items.capacity):
        if not try_reserve[K, V](items, items.capacity * 2 + 8):
            return false

    let entries = items.entries
    if entries == null:
        return false

    let hash = items.hash_fn(key)
    var index = index_for(hash, items.capacity)
    var probes: ptr_uint = 0
    var tombstone_index: ptr_uint = 0
    var has_tombstone = false

    while probes < items.capacity:
        unsafe:
            let slot = entries + index
            if slot.state == empty_state:
                var target_index = index
                if has_tombstone:
                    target_index = tombstone_index
                let target = entries + target_index
                target.key = key
                target.value = value_item
                target.hash = hash
                target.state = full_state
                items.len += 1
                return true
            elif slot.state == tombstone_state:
                if not has_tombstone:
                    tombstone_index = index
                    has_tombstone = true
            elif slot.hash == hash and items.equals_fn(slot.key, key):
                slot.value = value_item
                return true

        index = (index + 1) % items.capacity
        probes += 1

    if has_tombstone:
        unsafe:
            let target = entries + tombstone_index
            target.key = key
            target.value = value_item
            target.hash = hash
            target.state = full_state
        items.len += 1
        return true

    return false


public function put[K, V](items: ref[HashMap[K, V]], key: K, value_item: V) -> void:
    if not try_put[K, V](items, key, value_item):
        panic(c"map.put out of memory")
    return


public function get_into[K, V](items: HashMap[K, V], key: K, target: ref[V]) -> bool:
    if items.capacity == 0:
        return false

    let entries = items.entries
    if entries == null:
        return false

    let hash = items.hash_fn(key)
    var index = index_for(hash, items.capacity)
    var probes: ptr_uint = 0
    while probes < items.capacity:
        unsafe:
            let slot = entries + index
            if slot.state == empty_state:
                return false
            elif slot.state == full_state and slot.hash == hash and items.equals_fn(slot.key, key):
                read(target) = slot.value
                return true

        index = (index + 1) % items.capacity
        probes += 1

    return false


public function contains[K, V](items: HashMap[K, V], key: K) -> bool:
    if items.capacity == 0:
        return false

    let entries = items.entries
    if entries == null:
        return false

    let hash = items.hash_fn(key)
    var index = index_for(hash, items.capacity)
    var probes: ptr_uint = 0
    while probes < items.capacity:
        unsafe:
            let slot = entries + index
            if slot.state == empty_state:
                return false
            elif slot.state == full_state and slot.hash == hash and items.equals_fn(slot.key, key):
                return true

        index = (index + 1) % items.capacity
        probes += 1

    return false


public function remove[K, V](items: ref[HashMap[K, V]], key: K) -> bool:
    if items.capacity == 0:
        return false

    let entries = items.entries
    if entries == null:
        return false

    let hash = items.hash_fn(key)
    var index = index_for(hash, items.capacity)
    var probes: ptr_uint = 0
    while probes < items.capacity:
        unsafe:
            let slot = entries + index
            if slot.state == empty_state:
                return false
            elif slot.state == full_state and slot.hash == hash and items.equals_fn(slot.key, key):
                slot.state = tombstone_state
                items.len -= 1
                return true

        index = (index + 1) % items.capacity
        probes += 1

    return false
