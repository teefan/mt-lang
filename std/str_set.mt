module std.str_set

import std.hash as hash
import std.set as set


function hash_key(key: str) -> ulong:
    return hash.str_value(key)


function equal_key(left: str, right: str) -> bool:
    return hash.str_equal(left, right)

public struct StrSet:
    items: set.HashSet[str]


public function create() -> StrSet:
    return StrSet(items = set.create[str](hash_key, equal_key))


public function count(items: StrSet) -> ptr_uint:
    return set.count[str](items.items)


public function release(items: ref[StrSet]) -> void:
    set.release[str](ref_of(items.items))
    return


public function add(items: ref[StrSet], value_item: str) -> void:
    set.add[str](ref_of(items.items), value_item)
    return


public function try_add(items: ref[StrSet], value_item: str) -> bool:
    return set.try_add[str](ref_of(items.items), value_item)


public function contains(items: StrSet, value_item: str) -> bool:
    return set.contains[str](items.items, value_item)


public function remove(items: ref[StrSet], value_item: str) -> bool:
    return set.remove[str](ref_of(items.items), value_item)
