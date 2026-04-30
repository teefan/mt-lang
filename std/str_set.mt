module std.str_set

import std.hash as hash
import std.set as set

def hash_key(key: str) -> u64:
    return hash.str_value(key)

def equal_key(left: str, right: str) -> bool:
    return hash.str_equal(left, right)

pub struct StrSet:
    items: set.HashSet[str]

pub def create() -> StrSet:
    return StrSet(items = set.create[str](hash_key, equal_key))

pub def count(items: StrSet) -> usize:
    return set.count[str](items.items)

pub def release(items: ref[StrSet]) -> void:
    set.release[str](addr(items.items))
    return

pub def add(items: ref[StrSet], value_item: str) -> void:
    set.add[str](addr(items.items), value_item)
    return

pub def try_add(items: ref[StrSet], value_item: str) -> bool:
    return set.try_add[str](addr(items.items), value_item)

pub def contains(items: StrSet, value_item: str) -> bool:
    return set.contains[str](items.items, value_item)

pub def remove(items: ref[StrSet], value_item: str) -> bool:
    return set.remove[str](addr(items.items), value_item)
