module std.str_map

import std.hash as hash
import std.map as map

def hash_key(key: str) -> u64:
    return hash.str_value(key)

def equal_key(left: str, right: str) -> bool:
    return hash.str_equal(left, right)

pub struct StrMap[V]:
    items: map.HashMap[str, V]

pub def create[V]() -> StrMap[V]:
    return StrMap[V](items = map.create[str, V](hash_key, equal_key))

pub def count[V](items: StrMap[V]) -> usize:
    return map.count[str, V](items.items)

pub def release[V](items: ref[StrMap[V]]) -> void:
    map.release[str, V](addr(items.items))
    return

pub def put[V](items: ref[StrMap[V]], key: str, value_item: V) -> void:
    map.put[str, V](addr(items.items), key, value_item)
    return

pub def try_put[V](items: ref[StrMap[V]], key: str, value_item: V) -> bool:
    return map.try_put[str, V](addr(items.items), key, value_item)

pub def get_into[V](items: StrMap[V], key: str, target: ref[V]) -> bool:
    return map.get_into[str, V](items.items, key, target)

pub def contains[V](items: StrMap[V], key: str) -> bool:
    return map.contains[str, V](items.items, key)

pub def remove[V](items: ref[StrMap[V]], key: str) -> bool:
    return map.remove[str, V](addr(items.items), key)
