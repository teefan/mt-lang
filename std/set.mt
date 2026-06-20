import std.map as map

public struct Set[T]:
    values: map.Map[T, bool]


extending Set[T]:
    public static function create() -> Set[T]:
        return Set[T](values = map.Map[T, bool].create())


    public static function with_capacity(capacity: ptr_uint) -> Set[T]:
        var result = Set[T].create()
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


    public function at(value: T) -> Option[T]:
        let p = this.get(value) else:
            return Option[T].none

        unsafe:
            return Option[T].some(value = read(ptr[T]<-p))


    public function contains(value: T) -> bool:
        return this.values.contains(value)


    public function iter() -> map.Keys[T, bool]:
        return this.values.keys()


    public function is_subset(other: Set[T]) -> bool:
        if this.len() > other.len():
            return false

        for value in this:
            unsafe:
                if not other.contains(read(ptr[T]<-value)):
                    return false

        return true


    public function union_with(other: Set[T]) -> Set[T]:
        var result = Set[T].with_capacity(this.len() + other.len())

        for value in this:
            unsafe:
                result.insert(read(ptr[T]<-value))

        for value in other:
            unsafe:
                result.insert(read(ptr[T]<-value))

        return result


    public function intersection(other: Set[T]) -> Set[T]:
        var result = Set[T].with_capacity(this.len())

        if this.len() <= other.len():
            for value in this:
                unsafe:
                    let current = read(ptr[T]<-value)
                    if other.contains(current):
                        result.insert(current)
        else:
            for value in other:
                unsafe:
                    let current = read(ptr[T]<-value)
                    if this.contains(current):
                        result.insert(current)

        return result


    public function difference(other: Set[T]) -> Set[T]:
        var result = Set[T].with_capacity(this.len())

        for value in this:
            unsafe:
                let current = read(ptr[T]<-value)
                if not other.contains(current):
                    result.insert(current)

        return result


    public editable function clear() -> void:
        this.values.clear()


    public editable function release() -> void:
        this.values.release()


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public editable function insert(value: T) -> bool:
        return this.values.set(value, true).is_none()


    public editable function remove(value: T) -> bool:
        return this.values.remove(value).is_some()
