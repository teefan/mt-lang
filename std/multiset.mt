import std.counter as counter
import std.linked_map as linked_map
import std.maybe as maybe


public struct Entry[T]:
    value: const_ptr[T]
    count: ptr_uint


public struct Entries[T]:
    values: counter.Entries[T]


public struct MultiSet[T]:
    values: counter.Counter[T]


methods MultiSet[T]:
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
        return Entries[T](values = this.values.entries())


    public function iter() -> Entries[T]:
        return this.entries()


    public editable function clear() -> void:
        this.values.clear()
        return


    public editable function release() -> void:
        this.values.release()
        return


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)
        return


    public editable function insert(value: T) -> ptr_uint:
        return this.values.increment(value)


    public editable function add(value: T, amount: ptr_uint) -> ptr_uint:
        return this.values.add(value, amount)


    public editable function remove_one(value: T) -> bool:
        return this.values.remove_one(value)


    public editable function remove_all(value: T) -> maybe.Maybe[ptr_uint]:
        return this.values.remove(value)


methods Entries[T]:
    public function iter() -> Entries[T]:
        return this


    public editable function next() -> bool:
        return this.values.next()


    public function current() -> Entry[T]:
        let entry = this.values.current()
        return Entry[T](value = entry.key, count = entry.count)
