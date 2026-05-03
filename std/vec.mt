module std.vec

import std.mem.heap as heap
import std.span as sp

pub struct Vec[T]:
    data: ptr[T]?
    len: usize
    capacity: usize


pub def create[T]() -> Vec[T]:
    return Vec[T](data = null, len = 0, capacity = 0)


pub def with_capacity[T](capacity: usize) -> Vec[T]:
    var items = create[T]()
    reserve[T](ref_of(items), capacity)
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
    return sp.from_nullable_ptr[T](items.data, items.len)


pub def clear[T](items: ref[Vec[T]]) -> void:
    items.len = 0
    return


pub def release[T](items: ref[Vec[T]]) -> void:
    heap.release(items.data)
    items.data = null
    items.len = 0
    items.capacity = 0
    return


pub def try_reserve[T](items: ref[Vec[T]], min_capacity: usize) -> bool:
    if min_capacity <= items.capacity:
        return true

    var new_capacity = items.capacity
    if new_capacity == 0:
        new_capacity = 4

    while new_capacity < min_capacity:
        if new_capacity > heap.usize_max() / 2:
            new_capacity = min_capacity
        else:
            new_capacity *= 2

    let resized = heap.resize[T](items.data, new_capacity)
    if resized == null:
        return false

    items.data = resized
    items.capacity = new_capacity
    return true


pub def reserve[T](items: ref[Vec[T]], min_capacity: usize) -> void:
    if not try_reserve[T](items, min_capacity):
        panic(c"vec.reserve out of memory")
    return


pub def try_push[T](items: ref[Vec[T]], item: T) -> bool:
    if items.len == items.capacity:
        if not try_reserve[T](items, items.len + 1):
            return false

    let data = items.data
    if data == null:
        return false
    else:
        unsafe:
            read(data + items.len) = item

    items.len += 1
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
            return read(data + index)


pub def set[T](items: ref[Vec[T]], index: usize, item: T) -> void:
    if index >= items.len:
        panic(c"vec.set index out of bounds")

    let data = items.data
    if data == null:
        panic(c"vec.set missing storage")
    else:
        unsafe:
            read(data + index) = item
    return


pub def pop_into[T](items: ref[Vec[T]], target: ref[T]) -> bool:
    if items.len == 0:
        return false

    let last_index = items.len - 1
    let result = get[T](read(items), last_index)
    items.len -= 1
    read(target) = result
    return true


pub def remove_swap[T](items: ref[Vec[T]], index: usize) -> T:
    if index >= items.len:
        panic(c"vec.remove_swap index out of bounds")

    let last_index = items.len - 1
    let result = get[T](read(items), index)
    set[T](items, index, get[T](read(items), last_index))
    items.len = last_index
    return result


pub def remove_ordered[T](items: ref[Vec[T]], index: usize) -> T:
    if index >= items.len:
        panic(c"vec.remove_ordered index out of bounds")

    let result = get[T](read(items), index)
    var cursor = index
    while cursor + 1 < items.len:
        let next = cursor + 1
        set[T](items, cursor, get[T](read(items), next))
        cursor += 1

    items.len -= 1
    return result
