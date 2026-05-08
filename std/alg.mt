module std.alg


public function min_ptr_uint(left: ptr_uint, right: ptr_uint) -> ptr_uint:
    if left < right:
        return left
    return right


public function index_of[T](items: span[T], needle: T, equals: fn(left: T, right: T) -> bool, index_out: ref[ptr_uint]) -> bool:
    var index: ptr_uint = 0
    while index < items.len:
        if equals(items[index], needle):
            read(index_out) = index
            return true
        index += 1
    return false


public function contains[T](items: span[T], needle: T, equals: fn(left: T, right: T) -> bool) -> bool:
    var index: ptr_uint = 0
    while index < items.len:
        if equals(items[index], needle):
            return true
        index += 1
    return false


public function equal[T](left: span[T], right: span[T], equals: fn(left: T, right: T) -> bool) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        if not equals(left[index], right[index]):
            return false
        index += 1
    return true


public function any[T](items: span[T], predicate: fn(value: T) -> bool) -> bool:
    var index: ptr_uint = 0
    while index < items.len:
        if predicate(items[index]):
            return true
        index += 1
    return false


public function all[T](items: span[T], predicate: fn(value: T) -> bool) -> bool:
    var index: ptr_uint = 0
    while index < items.len:
        if not predicate(items[index]):
            return false
        index += 1
    return true


public function count_if[T](items: span[T], predicate: fn(value: T) -> bool) -> ptr_uint:
    var total: ptr_uint = 0
    var index: ptr_uint = 0
    while index < items.len:
        if predicate(items[index]):
            total += 1
        index += 1
    return total


public function fill[T](items: span[T], value_item: T) -> void:
    var index: ptr_uint = 0
    while index < items.len:
        items[index] = value_item
        index += 1
    return


public function copy[T](target: span[T], source: span[T]) -> ptr_uint:
    let count = min_ptr_uint(target.len, source.len)
    var index: ptr_uint = 0
    while index < count:
        target[index] = source[index]
        index += 1
    return count


public function sort[T](items: span[T], less: fn(left: T, right: T) -> bool) -> void:
    var index: ptr_uint = 1
    while index < items.len:
        let item = items[index]
        var hole = index
        while hole > 0 and less(item, items[hole - 1]):
            items[hole] = items[hole - 1]
            hole -= 1
        items[hole] = item
        index += 1
    return
