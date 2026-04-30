module std.set

import std.map as map

pub struct HashSet[T]:
    items: map.HashMap[T, bool]

pub def create[T](hash_fn: fn(key: T) -> u64, equals_fn: fn(left: T, right: T) -> bool) -> HashSet[T]:
    return HashSet[T](items = map.create[T, bool](hash_fn, equals_fn))

pub def count[T](items: HashSet[T]) -> usize:
    return map.count[T, bool](items.items)

pub def release[T](items: ref[HashSet[T]]) -> void:
    map.release[T, bool](ref_of(items.items))
    return

pub def add[T](items: ref[HashSet[T]], value_item: T) -> void:
    map.put[T, bool](ref_of(items.items), value_item, true)
    return

pub def try_add[T](items: ref[HashSet[T]], value_item: T) -> bool:
    return map.try_put[T, bool](ref_of(items.items), value_item, true)

pub def contains[T](items: HashSet[T], value_item: T) -> bool:
    return map.contains[T, bool](items.items, value_item)

pub def remove[T](items: ref[HashSet[T]], value_item: T) -> bool:
    return map.remove[T, bool](ref_of(items.items), value_item)
