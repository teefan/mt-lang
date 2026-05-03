module std.alg

pub def min_usize(left: usize, right: usize) -> usize:
    if left < right:
        return left
    return right

pub def index_of[T](items: span[T], needle: T, equals: fn(left: T, right: T) -> bool, index_out: ref[usize]) -> bool:
    var index: usize = 0
    while index < items.len:
        if equals(items[index], needle):
            read(index_out) = index
            return true
        index += 1
    return false

pub def contains[T](items: span[T], needle: T, equals: fn(left: T, right: T) -> bool) -> bool:
    var index: usize = 0
    while index < items.len:
        if equals(items[index], needle):
            return true
        index += 1
    return false

pub def equal[T](left: span[T], right: span[T], equals: fn(left: T, right: T) -> bool) -> bool:
    if left.len != right.len:
        return false

    var index: usize = 0
    while index < left.len:
        if not equals(left[index], right[index]):
            return false
        index += 1
    return true

pub def any[T](items: span[T], predicate: fn(value: T) -> bool) -> bool:
    var index: usize = 0
    while index < items.len:
        if predicate(items[index]):
            return true
        index += 1
    return false

pub def all[T](items: span[T], predicate: fn(value: T) -> bool) -> bool:
    var index: usize = 0
    while index < items.len:
        if not predicate(items[index]):
            return false
        index += 1
    return true

pub def count_if[T](items: span[T], predicate: fn(value: T) -> bool) -> usize:
    var total: usize = 0
    var index: usize = 0
    while index < items.len:
        if predicate(items[index]):
            total += 1
        index += 1
    return total

pub def fill[T](items: span[T], value_item: T) -> void:
    var index: usize = 0
    while index < items.len:
        items[index] = value_item
        index += 1
    return

pub def copy[T](target: span[T], source: span[T]) -> usize:
    let count = min_usize(target.len, source.len)
    var index: usize = 0
    while index < count:
        target[index] = source[index]
        index += 1
    return count

pub def sort[T](items: span[T], less: fn(left: T, right: T) -> bool) -> void:
    var index: usize = 1
    while index < items.len:
        let item = items[index]
        var hole = index
        while hole > 0 and less(item, items[hole - 1]):
            items[hole] = items[hole - 1]
            hole -= 1
        items[hole] = item
        index += 1
    return