import std.linked_map as linked_map

public struct LruCache[K, V]:
    values: linked_map.LinkedMap[K, V]
    max_capacity: ptr_uint


extending LruCache[K, V]:
    public static function with_capacity(capacity: ptr_uint) -> LruCache[K, V]:
        return LruCache[K, V](values = linked_map.LinkedMap[K, V].with_capacity(capacity), max_capacity = capacity)


    public function len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.max_capacity


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function iter() -> linked_map.Entries[K, V]:
        return this.values.entries()


    public editable function get(key: K) -> ptr[V]?:
        let removed = this.values.remove_entry(key)
        match removed:
            Option.some as entry:
                this.values.set(key, entry.value.value)
                return this.values.get(key)
            Option.none:
                return null


    public editable function at(key: K) -> Option[V]:
        let p = this.get(key) else:
            return Option[V].none

        unsafe:
            return Option[V].some(value = read(p))


    public function contains(key: K) -> bool:
        return this.values.contains(key)


    public editable function clear() -> void:
        this.values.clear()


    public editable function release() -> void:
        this.values.release()


    public editable function set(key: K, value: V) -> void:
        this.values.remove(key)

        if this.values.len() == this.max_capacity:
            var key_iter = this.values.keys()
            let first_key_ptr = key_iter.next() else:
                return

            unsafe:
                let first_key = read(ptr[K]<-first_key_ptr)
                this.values.remove(first_key)

        this.values.set(key, value)


    public editable function remove(key: K) -> bool:
        return this.values.remove(key).is_some()
