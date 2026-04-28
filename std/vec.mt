module std.vec

import std.mem.heap as heap

pub struct Vec[T]:
    data: ptr[T]?
    len: usize
    capacity: usize

pub def create[T]() -> Vec[T]:
    return Vec[T](data = null, len = 0, capacity = 0)

pub def with_capacity[T](capacity: usize) -> Vec[T]:
    var items = create[T]()
    reserve[T](addr(items), capacity)
    return items

pub def count[T](items: Vec[T]) -> usize:
    return items.len

pub def capacity[T](items: Vec[T]) -> usize:
    return items.capacity

pub def is_empty[T](items: Vec[T]) -> bool:
    return items.len == 0

pub def data_ptr[T](items: Vec[T]) -> ptr[T]?:
    return items.data

pub def as_span[T](items: Vec[T]) -> span[T]:
    let data = items.data
    unsafe:
        return span[T](data = cast[ptr[T]](data), len = items.len)

pub def clear[T](items: ref[Vec[T]]) -> void:
    value(items).len = 0
    return

pub def release[T](items: ref[Vec[T]]) -> void:
    heap.release(value(items).data)
    value(items).data = null
    value(items).len = 0
    value(items).capacity = 0
    return

pub def try_reserve[T](items: ref[Vec[T]], min_capacity: usize) -> bool:
    if min_capacity <= value(items).capacity:
        return true

    var new_capacity = value(items).capacity
    if new_capacity == 0:
        new_capacity = 4

    while new_capacity < min_capacity:
        if new_capacity > heap.usize_max() / 2:
            new_capacity = min_capacity
        else:
            new_capacity *= 2

    let resized = heap.resize[T](value(items).data, new_capacity)
    if resized == null:
        return false

    value(items).data = resized
    value(items).capacity = new_capacity
    return true

pub def reserve[T](items: ref[Vec[T]], min_capacity: usize) -> void:
    if not try_reserve[T](items, min_capacity):
        panic(c"vec.reserve out of memory")
    return

pub def try_push[T](items: ref[Vec[T]], item: T) -> bool:
    if value(items).len == value(items).capacity:
        if not try_reserve[T](items, value(items).len + 1):
            return false

    let data = value(items).data
    if data == null:
        return false
    else:
        unsafe:
            deref(data + value(items).len) = item

    value(items).len += 1
    return true

pub def push[T](items: ref[Vec[T]], item: T) -> void:
    if not try_push[T](items, item):
        panic(c"vec.push out of memory")
    return

pub def get[T](items: Vec[T], index: usize) -> T:
    if index >= items.len:
        panic(c"vec.get index out of bounds")

    let data = items.data
    if data == null:
        panic(c"vec.get missing storage")
    else:
        unsafe:
            return deref(data + index)

pub def set[T](items: ref[Vec[T]], index: usize, item: T) -> void:
    if index >= value(items).len:
        panic(c"vec.set index out of bounds")

    let data = value(items).data
    if data == null:
        panic(c"vec.set missing storage")
    else:
        unsafe:
            deref(data + index) = item
    return

pub def pop_into[T](items: ref[Vec[T]], target: ref[T]) -> bool:
    if value(items).len == 0:
        return false

    let last_index = value(items).len - 1
    let result = get[T](value(items), last_index)
    value(items).len -= 1
    value(target) = result
    return true

pub def remove_swap[T](items: ref[Vec[T]], index: usize) -> T:
    if index >= value(items).len:
        panic(c"vec.remove_swap index out of bounds")

    let last_index = value(items).len - 1
    let result = get[T](value(items), index)
    set[T](items, index, get[T](value(items), last_index))
    value(items).len = last_index
    return result

pub def remove_ordered[T](items: ref[Vec[T]], index: usize) -> T:
    if index >= value(items).len:
        panic(c"vec.remove_ordered index out of bounds")

    let result = get[T](value(items), index)
    var cursor = index
    while cursor + 1 < value(items).len:
        let next = cursor + 1
        set[T](items, cursor, get[T](value(items), next))
        cursor += 1

    value(items).len -= 1
    return result
