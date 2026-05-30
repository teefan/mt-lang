import std.counter as counter
import std.linked_map as linked_map
import std.linked_map_view as linked_map_view

public struct Entry[T]:
    value: const_ptr[T]
    count: ptr_uint

public struct Entries[T]:
    values: linked_map_view.SnapshotEntries[T, ptr_uint]

public struct MultiSet[T]:
    values: counter.Counter[T]


extending MultiSet[T]:
    public static function create() -> MultiSet[T]:
        return MultiSet[T](values = counter.Counter[T].create())


    public static function with_capacity(capacity: ptr_uint) -> MultiSet[T]:
        var result = MultiSet[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.values.total_count()


    public function total_count() -> ptr_uint:
        return this.values.total_count()


    public function distinct_len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function count(value: T) -> ptr_uint:
        return this.values.count(value)


    public function contains(value: T) -> bool:
        return this.values.contains(value)


    public function values() -> linked_map.Keys[T, ptr_uint]:
        return this.values.keys()


    public function entries() -> Entries[T]:
        return Entries[T](values = linked_map_view.SnapshotEntries[T, ptr_uint].create(this.values.values.entries()))


    public function iter() -> Entries[T]:
        return this.entries()


    public function is_subset(other: MultiSet[T]) -> bool:
        if this.total_count() > other.total_count():
            return false

        for entry in this:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                if entry.count > other.count(current):
                    return false

        return true


    public function union_with(other: MultiSet[T]) -> MultiSet[T]:
        var result = MultiSet[T].with_capacity(this.distinct_len() + other.distinct_len())

        for entry in this:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                var count = entry.count
                let other_count = other.count(current)
                if other_count > count:
                    count = other_count
                result.add(current, count)

        for entry in other:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                if not result.contains(current):
                    result.add(current, entry.count)

        return result


    public function intersection(other: MultiSet[T]) -> MultiSet[T]:
        var result = MultiSet[T].with_capacity(this.distinct_len())

        for entry in this:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                let other_count = other.count(current)
                if other_count != 0:
                    var count = entry.count
                    if other_count < count:
                        count = other_count
                    result.add(current, count)

        return result


    public function difference(other: MultiSet[T]) -> MultiSet[T]:
        var result = MultiSet[T].with_capacity(this.distinct_len())

        for entry in this:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                let other_count = other.count(current)
                if entry.count > other_count:
                    result.add(current, entry.count - other_count)

        return result


    public function symmetric_difference(other: MultiSet[T]) -> MultiSet[T]:
        var result = MultiSet[T].with_capacity(this.distinct_len() + other.distinct_len())

        for entry in this:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                let other_count = other.count(current)
                if entry.count != other_count:
                    if entry.count > other_count:
                        result.add(current, entry.count - other_count)
                    else:
                        result.add(current, other_count - entry.count)

        for entry in other:
            unsafe:
                let current = read(ptr[T]<-entry.value)
                if not this.contains(current):
                    result.add(current, entry.count)

        return result


    public mutable function clear() -> void:
        this.values.clear()


    public mutable function release() -> void:
        this.values.release()


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public mutable function insert(value: T) -> ptr_uint:
        return this.values.increment(value)


    public mutable function add(value: T, amount: ptr_uint) -> ptr_uint:
        return this.values.add(value, amount)


    public mutable function remove_one(value: T) -> bool:
        return this.values.remove_one(value)


    public mutable function remove_all(value: T) -> Option[ptr_uint]:
        return this.values.remove(value)


extending Entries[T]:
    public function iter() -> Entries[T]:
        return this


    public mutable function next() -> bool:
        return this.values.next()


    public function current() -> Entry[T]:
        let entry = this.values.current()
        return Entry[T](value = entry.key, count = entry.value)
