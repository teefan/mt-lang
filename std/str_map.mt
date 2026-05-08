module std.str_map

import std.hash as hash
import std.map as map


function hash_key(key: str) -> ulong:
    return hash.str_value(key)


function equal_key(left: str, right: str) -> bool:
    return hash.str_equal(left, right)

public struct StrMap[V]:
    items: map.HashMap[str, V]


public function create[V]() -> StrMap[V]:
    return StrMap[V](items = map.create[str, V](hash_key, equal_key))


public function count[V](items: StrMap[V]) -> ptr_uint:
    return map.count[str, V](items.items)


public function release[V](items: ref[StrMap[V]]) -> void:
    map.release[str, V](ref_of(items.items))
    return


public function put[V](items: ref[StrMap[V]], key: str, value_item: V) -> void:
    map.put[str, V](ref_of(items.items), key, value_item)
    return


public function try_put[V](items: ref[StrMap[V]], key: str, value_item: V) -> bool:
    return map.try_put[str, V](ref_of(items.items), key, value_item)


public function get_into[V](items: StrMap[V], key: str, target: ref[V]) -> bool:
    return map.get_into[str, V](items.items, key, target)


public function contains[V](items: StrMap[V], key: str) -> bool:
    return map.contains[str, V](items.items, key)


public function remove[V](items: ref[StrMap[V]], key: str) -> bool:
    return map.remove[str, V](ref_of(items.items), key)
