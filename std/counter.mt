import std.linked_map as linked_map
import std.linked_map_view as linked_map_view
import std.mem.heap as heap

public struct Entry[T]:
    key: const_ptr[T]
    count: ptr_uint

public struct Entries[T]:
    values: linked_map_view.SnapshotEntries[T, ptr_uint]

public struct Counter[T]:
    values: linked_map.LinkedMap[T, ptr_uint]
    total: ptr_uint


extending Counter[T]:
    public static function create() -> Counter[T]:
        return Counter[T](values = linked_map.LinkedMap[T, ptr_uint].create(), total = 0)


    public static function with_capacity(capacity: ptr_uint) -> Counter[T]:
        var result = Counter[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.values.len()


    public function total_count() -> ptr_uint:
        return this.total


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.total == 0


    public function count(value: T) -> ptr_uint:
        let stored = this.values.get(value) else:
            return 0

        unsafe:
            return read(stored)


    public function contains(value: T) -> bool:
        return this.values.contains(value)


    public function iter() -> Entries[T]:
        return this.entries()


    public function keys() -> linked_map.Keys[T, ptr_uint]:
        return this.values.keys()


    public function counts() -> linked_map_view.SnapshotValues[T, ptr_uint]:
        return linked_map_view.SnapshotValues[T, ptr_uint].create(this.values.entries())


    public function entries() -> Entries[T]:
        return Entries[T](values = linked_map_view.SnapshotEntries[T, ptr_uint].create(this.values.entries()))


    public mutable function clear() -> void:
        this.values.clear()
        this.total = 0


    public mutable function release() -> void:
        this.values.release()
        this.total = 0


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public mutable function add(value: T, amount: ptr_uint) -> ptr_uint:
        if amount == 0:
            let stored = this.values.get(value) else:
                return 0

            unsafe:
                return read(stored)

        if this.total > heap.ptr_uint_max() - amount:
            fatal(c"counter.Counter.add total count overflow")

        let current = this.values.get_or_insert(value, ptr_uint<-0)
        unsafe:
            if read(current) > heap.ptr_uint_max() - amount:
                fatal(c"counter.Counter.add entry count overflow")
            read(current) += amount

        this.total += amount
        unsafe:
            return read(current)


    public mutable function increment(value: T) -> ptr_uint:
        return this.add(value, 1)


    public mutable function remove_one(value: T) -> bool:
        let current = this.values.get(value) else:
            return false

        unsafe:
            let count = read(current)
            if count <= 1:
                let removed = this.values.remove(value)
                match removed:
                    Option.none:
                        fatal(c"counter.Counter.remove_one missing value")
                    Option.some:
                        if this.total == 0:
                            fatal(c"counter.Counter.remove_one missing total")
                        this.total -= 1
                        return true

            read(current) = count - 1

        if this.total == 0:
            fatal(c"counter.Counter.remove_one missing total")
        this.total -= 1
        return true


    public mutable function remove(value: T) -> Option[ptr_uint]:
        let removed = this.values.remove(value)
        match removed:
            Option.none:
                return Option[ptr_uint].none
            Option.some as payload:
                if this.total < payload.value:
                    fatal(c"counter.Counter.remove total underflow")
                this.total -= payload.value
                return Option[ptr_uint].some(value = payload.value)


extending Entries[T]:
    public function iter() -> Entries[T]:
        return this


    public mutable function next() -> bool:
        return this.values.next()


    public function current() -> Entry[T]:
        let entry = this.values.current()
        return Entry[T](key = entry.key, count = entry.value)
