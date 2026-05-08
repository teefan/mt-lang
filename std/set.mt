module std.set

import std.map as map

public struct HashSet[T]:
    items: map.HashMap[T, bool]


public function create[T](hash_fn: fn(key: T) -> ulong, equals_fn: fn(left: T, right: T) -> bool) -> HashSet[T]:
    return HashSet[T](items = map.create[T, bool](hash_fn, equals_fn))


public function count[T](items: HashSet[T]) -> ptr_uint:
    return map.count[T, bool](items.items)


public function release[T](items: ref[HashSet[T]]) -> void:
    map.release[T, bool](ref_of(items.items))
    return


public function add[T](items: ref[HashSet[T]], value_item: T) -> void:
    map.put[T, bool](ref_of(items.items), value_item, true)
    return


public function try_add[T](items: ref[HashSet[T]], value_item: T) -> bool:
    return map.try_put[T, bool](ref_of(items.items), value_item, true)


public function contains[T](items: HashSet[T], value_item: T) -> bool:
    return map.contains[T, bool](items.items, value_item)


public function remove[T](items: ref[HashSet[T]], value_item: T) -> bool:
    return map.remove[T, bool](ref_of(items.items), value_item)
