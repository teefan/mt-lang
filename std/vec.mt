module std.vec

import std.mem.heap as heap
import std.maybe as maybe
import std.span as sp

pub struct Vec[T]:
    data: ptr[T]?
    len: ptr_uint
    capacity: ptr_uint

methods Vec[T]:
    pub static def create() -> Vec[T]:
        return Vec[T](data = null, len = 0, capacity = 0)


    pub static def with_capacity(capacity: ptr_uint) -> Vec[T]:
        var items = Vec[T](data = null, len = 0, capacity = 0)
        items.reserve(capacity)
        return items


    pub def count() -> ptr_uint:
        return this.len


    pub def capacity() -> ptr_uint:
        return this.capacity


    pub def is_empty() -> bool:
        return this.len == 0


    pub def data_ptr() -> ptr[T]?:
        return this.data


    pub def as_span() -> span[T]:
        return sp.from_nullable_ptr[T](this.data, this.len)


    pub edit def clear() -> void:
        this.len = 0
        return


    pub edit def release() -> void:
        heap.release(this.data)
        this.data = null
        this.len = 0
        this.capacity = 0
        return


    pub edit def try_reserve(min_capacity: ptr_uint) -> bool:
        if min_capacity <= this.capacity:
            return true

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
            return false

        this.data = resized
        this.capacity = new_capacity
        return true


    pub edit def reserve(min_capacity: ptr_uint) -> void:
        if not this.try_reserve(min_capacity):
            panic(c"vec.reserve out of memory")
        return


    pub edit def try_push(item: T) -> bool:
        if this.len == this.capacity:
            if not this.try_reserve(this.len + 1):
                return false

        let data = this.data
        if data == null:
            return false

        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + this.len) = item

        this.len += 1
        return true


    pub edit def push(item: T) -> void:
        if not this.try_push(item):
            panic(c"vec.push out of memory")
        return


    pub def get(index: ptr_uint) -> T:
        if index >= this.len:
            panic(c"vec.get index out of bounds")

        let data = this.data
        if data == null:
            panic(c"vec.get missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            return read(data_ptr + index)


    pub edit def set(index: ptr_uint, item: T) -> void:
        if index >= this.len:
            panic(c"vec.set index out of bounds")

        let data = this.data
        if data == null:
            panic(c"vec.set missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + index) = item
        return


    pub edit def pop() -> maybe.Maybe[T]:
        if this.len == 0:
            return maybe.Maybe[T].none

        let last_index = this.len - 1
        let data = this.data
        if data == null:
            panic(c"vec.pop missing storage")

        this.len -= 1
        unsafe:
            let data_ptr = ptr[T]<-data
            return maybe.Maybe[T].some(value= read(data_ptr + last_index))

    pub edit def remove_swap(index: ptr_uint) -> T:
        if index >= this.len:
            panic(c"vec.remove_swap index out of bounds")

        let last_index = this.len - 1
        let data = this.data
        if data == null:
            panic(c"vec.remove_swap missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            let result = read(data_ptr + index)
            read(data_ptr + index) = read(data_ptr + last_index)
            this.len = last_index
            return result


    pub edit def remove_ordered(index: ptr_uint) -> T:
        if index >= this.len:
            panic(c"vec.remove_ordered index out of bounds")

        let data = this.data
        if data == null:
            panic(c"vec.remove_ordered missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            let result = read(data_ptr + index)
            var cursor = index
            while cursor + 1 < this.len:
                let next = cursor + 1
                read(data_ptr + cursor) = read(data_ptr + next)
                cursor += 1

            this.len -= 1
            return result
