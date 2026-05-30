import std.linked_map as linked_map

public struct LinkedSet[T]:
    values: linked_map.LinkedMap[T, bool]


extending LinkedSet[T]:
    public static function create() -> LinkedSet[T]:
        return LinkedSet[T](values = linked_map.LinkedMap[T, bool].create())


    public static function with_capacity(capacity: ptr_uint) -> LinkedSet[T]:
        var result = LinkedSet[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function get(value: T) -> const_ptr[T]?:
        return this.values.get_key(value)


    public function contains(value: T) -> bool:
        return this.values.contains(value)


    public function iter() -> linked_map.Keys[T, bool]:
        return this.values.keys()


    public function is_subset(other: LinkedSet[T]) -> bool:
        if this.len() > other.len():
            return false

        for value in this:
            unsafe:
                if not other.contains(read(ptr[T]<-value)):
                    return false

        return true


    public function union_with(other: LinkedSet[T]) -> LinkedSet[T]:
        var result = LinkedSet[T].with_capacity(this.len() + other.len())

        for value in this:
            unsafe:
                result.insert(read(ptr[T]<-value))

        for value in other:
            unsafe:
                result.insert(read(ptr[T]<-value))

        return result


    public function intersection(other: LinkedSet[T]) -> LinkedSet[T]:
        var result = LinkedSet[T].with_capacity(this.len())

        for value in this:
            unsafe:
                let current = read(ptr[T]<-value)
                if other.contains(current):
                    result.insert(current)

        return result


    public function difference(other: LinkedSet[T]) -> LinkedSet[T]:
        var result = LinkedSet[T].with_capacity(this.len())

        for value in this:
            unsafe:
                let current = read(ptr[T]<-value)
                if not other.contains(current):
                    result.insert(current)

        return result


    public mutable function clear() -> void:
        this.values.clear()


    public mutable function release() -> void:
        this.values.release()


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public mutable function insert(value: T) -> bool:
        let previous = this.values.set(value, true)
        match previous:
            Option.none:
                return true
            Option.some:
                return false


    public mutable function remove(value: T) -> bool:
        let removed = this.values.remove(value)
        match removed:
            Option.none:
                return false
            Option.some:
                return true
