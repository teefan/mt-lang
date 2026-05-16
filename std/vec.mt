import std.mem.heap as heap
import std.maybe as maybe


public struct Vec[T]:
    data: ptr[T]?
    len: ptr_uint
    capacity: ptr_uint


public struct Iter[T]:
    data: ptr[T]?
    index: ptr_uint
    len: ptr_uint


methods Vec[T]:
    public static function create() -> Vec[T]:
        return Vec[T](data = null, len = 0, capacity = 0)


    public static function with_capacity(capacity: ptr_uint) -> Vec[T]:
        var result = Vec[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public function iter() -> Iter[T]:
        return Iter[T](data = this.data, index = 0, len = this.len)


    public function as_span() -> span[T]:
        if this.data == null and this.len != 0:
            fatal(c"vec.Vec.as_span missing storage")

        return unsafe: span[T](data = ptr[T]<-this.data, len = this.len)


    public function get(index: ptr_uint) -> ptr[T]?:
        if index >= this.len:
            return null

        let data = this.data
        if data == null:
            fatal(c"vec.Vec.get missing storage")

        return unsafe: ptr[T]<-data + index


    public function first() -> ptr[T]?:
        return this.get(0)


    public function last() -> ptr[T]?:
        if this.len == 0:
            return null

        return this.get(this.len - 1)


    public editable function clear() -> void:
        this.len = 0
        return


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.len = 0
        this.capacity = 0
        return


    public editable function reserve(min_capacity: ptr_uint) -> void:
        if min_capacity <= this.capacity:
            return

        var new_capacity = this.capacity
        if new_capacity == 0:
            new_capacity = 4

        while new_capacity < min_capacity:
            if new_capacity > heap.ptr_uint_max() / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let resized = heap.resize[T](this.data, new_capacity)
        if resized == null:
            fatal(c"vec.reserve out of memory")

        this.data = resized
        this.capacity = new_capacity
        return


    public editable function append_span(values: span[T]) -> void:
        if values.len == 0:
            return

        let current_len = this.len
        if values.len > heap.ptr_uint_max() - current_len:
            fatal(c"vec.append_span size overflow")

        let new_len = current_len + values.len
        let needs_growth = new_len > this.capacity

        var copied: ptr[T]? = null
        if needs_growth:
            copied = heap.must_alloc[T](values.len)
            unsafe:
                let copied_ptr = ptr[T]<-copied
                var index: ptr_uint = 0
                while index < values.len:
                    read(copied_ptr + index) = read(values.data + index)
                    index += 1

        this.reserve(new_len)

        let data = this.data
        if data == null:
            fatal(c"vec.append_span missing storage")

        unsafe:
            let destination = ptr[T]<-data + current_len
            if copied != null:
                let copied_ptr = ptr[T]<-copied
                var index: ptr_uint = 0
                while index < values.len:
                    read(destination + index) = read(copied_ptr + index)
                    index += 1
                heap.release(copied)
            else:
                var index: ptr_uint = 0
                while index < values.len:
                    read(destination + index) = read(values.data + index)
                    index += 1

        this.len = new_len
        return


    public editable function append_array[N](values: array[T, N]) -> void:
        var local_values = values
        this.append_span(local_values)
        return


    public editable function insert(index: ptr_uint, value: T) -> bool:
        if index > this.len:
            return false

        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data
        if data == null:
            fatal(c"vec.insert missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            var current = this.len
            while current > index:
                let previous = current - 1
                read(data_ptr + current) = read(data_ptr + previous)
                current = previous
            read(data_ptr + index) = value

        this.len += 1
        return true


    public editable function push(value: T) -> void:
        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data
        if data == null:
            fatal(c"vec.push missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + this.len) = value

        this.len += 1
        return


    public editable function pop() -> maybe.Maybe[T]:
        if this.len == 0:
            return maybe.Maybe[T].none

        let data = this.data
        if data == null:
            fatal(c"vec.pop missing storage")

        let last_index = this.len - 1
        unsafe:
            let data_ptr = ptr[T]<-data
            let value = read(data_ptr + last_index)
            this.len = last_index
            return maybe.Maybe[T].some(value = value)


    public editable function remove(index: ptr_uint) -> maybe.Maybe[T]:
        if index >= this.len:
            return maybe.Maybe[T].none

        let data = this.data
        if data == null:
            fatal(c"vec.remove missing storage")

        let last_index = this.len - 1
        unsafe:
            let data_ptr = ptr[T]<-data
            let removed = read(data_ptr + index)
            var current = index
            while current < last_index:
                let next_index = current + 1
                read(data_ptr + current) = read(data_ptr + next_index)
                current = next_index
            this.len = last_index
            return maybe.Maybe[T].some(value = removed)


    public editable function swap_remove(index: ptr_uint) -> maybe.Maybe[T]:
        if index >= this.len:
            return maybe.Maybe[T].none

        let data = this.data
        if data == null:
            fatal(c"vec.swap_remove missing storage")

        let last_index = this.len - 1
        unsafe:
            let data_ptr = ptr[T]<-data
            let removed = read(data_ptr + index)
            if index != last_index:
                read(data_ptr + index) = read(data_ptr + last_index)
            this.len = last_index
            return maybe.Maybe[T].some(value = removed)


methods Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public editable function next() -> ptr[T]?:
        if this.index >= this.len:
            return null

        let data = this.data
        if data == null:
            fatal(c"vec.Iter.next missing storage")

        let current_index = this.index
        this.index += 1
        return unsafe: ptr[T]<-data + current_index
