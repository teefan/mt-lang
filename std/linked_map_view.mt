import std.linked_map as linked_map

public struct SnapshotEntry[K, V]:
    key: const_ptr[K]
    value: V

public struct SnapshotValues[K, V]:
    values: linked_map.Entries[K, V]

public struct SnapshotEntries[K, V]:
    values: linked_map.Entries[K, V]


extending SnapshotValues[K, V]:
    public static function create(values: linked_map.Entries[K, V]) -> SnapshotValues[K, V]:
        return SnapshotValues[K, V](values = values)


    public function iter() -> SnapshotValues[K, V]:
        return this


    public editable function next() -> bool:
        return this.values.next()


    public function current() -> V:
        let entry = this.values.current()
        unsafe:
            return read(entry.value)


extending SnapshotEntries[K, V]:
    public static function create(values: linked_map.Entries[K, V]) -> SnapshotEntries[K, V]:
        return SnapshotEntries[K, V](values = values)


    public function iter() -> SnapshotEntries[K, V]:
        return this


    public editable function next() -> bool:
        return this.values.next()


    public function current() -> SnapshotEntry[K, V]:
        let entry = this.values.current()
        unsafe:
            return SnapshotEntry[K, V](key = entry.key, value = read(entry.value))
