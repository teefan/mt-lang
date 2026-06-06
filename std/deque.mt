import std.mem.heap as heap

public struct Deque[T]:
    data: ptr[T]?
    head: ptr_uint
    len: ptr_uint
    capacity: ptr_uint

public struct Iter[T]:
    data: ptr[T]?
    head: ptr_uint
    len: ptr_uint
    capacity: ptr_uint
    index: ptr_uint


extending Deque[T]:
    public static function create() -> Deque[T]:
        return Deque[T](data = null, head = 0, len = 0, capacity = 0)


    public static function with_capacity(capacity: ptr_uint) -> Deque[T]:
        var result = Deque[T].create()
        result.reserve(capacity)
        return result


    static function physical_index(head: ptr_uint, capacity: ptr_uint, index: ptr_uint) -> ptr_uint:
        let raw = head + index
        if raw >= capacity:
            return raw - capacity

        return raw


    static function next_index(index: ptr_uint, capacity: ptr_uint) -> ptr_uint:
        if index + 1 == capacity:
            return 0

        return index + 1


    static function previous_index(index: ptr_uint, capacity: ptr_uint) -> ptr_uint:
        if index == 0:
            return capacity - 1

        return index - 1


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public function iter() -> Iter[T]:
        return Iter[T](data = this.data, head = this.head, len = this.len, capacity = this.capacity, index = 0)


    public function get(index: ptr_uint) -> ptr[T]?:
        if index >= this.len:
            return null

        let data = this.data else:
            fatal(c"deque.Deque.get missing storage")

        return unsafe: ptr[T]<-data + Deque[T].physical_index(this.head, this.capacity, index)


    public function first() -> ptr[T]?:
        return this.get(0)


    public function last() -> ptr[T]?:
        if this.len == 0:
            return null

        return this.get(this.len - 1)


    public editable function clear() -> void:
        this.head = 0
        this.len = 0


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.head = 0
        this.len = 0
        this.capacity = 0


    public editable function reserve(min_capacity: ptr_uint) -> void:
        if min_capacity <= this.capacity:
            return

        var new_capacity = this.capacity
        if new_capacity == 0:
            new_capacity = 4

        while new_capacity < min_capacity:
            if new_capacity > heap.ptr_uint_max / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let new_data = heap.must_alloc[T](new_capacity)
        let old_data = this.data
        if this.len != 0:
            if old_data == null:
                fatal(c"deque.reserve missing storage")

            unsafe:
                let old_ptr = ptr[T]<-old_data
                let new_ptr = ptr[T]<-new_data
                var index: ptr_uint = 0
                while index < this.len:
                    let source_index = Deque[T].physical_index(this.head, this.capacity, index)
                    read(new_ptr + index) = read(old_ptr + source_index)
                    index += 1

        heap.release(old_data)
        this.data = new_data
        this.head = 0
        this.capacity = new_capacity


    public editable function push_back(value: T) -> void:
        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data else:
            fatal(c"deque.push_back missing storage")

        let tail_index = Deque[T].physical_index(this.head, this.capacity, this.len)
        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + tail_index) = value

        this.len += 1


    public editable function push_front(value: T) -> void:
        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data else:
            fatal(c"deque.push_front missing storage")

        if this.len == 0:
            this.head = 0
        else:
            this.head = Deque[T].previous_index(this.head, this.capacity)

        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + this.head) = value

        this.len += 1


    public editable function insert(index: ptr_uint, value: T) -> bool:
        if index > this.len:
            return false

        if index == 0:
            this.push_front(value)
            return true

        if index == this.len:
            this.push_back(value)
            return true

        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data else:
            fatal(c"deque.insert missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            if index < this.len - index:
                let old_head = this.head
                let new_head = Deque[T].previous_index(old_head, this.capacity)
                var current: ptr_uint = 0
                while current < index:
                    let destination = Deque[T].physical_index(new_head, this.capacity, current)
                    let source = Deque[T].physical_index(old_head, this.capacity, current)
                    read(data_ptr + destination) = read(data_ptr + source)
                    current += 1
                this.head = new_head
            else:
                var current = this.len
                while current > index:
                    let destination = Deque[T].physical_index(this.head, this.capacity, current)
                    let source = Deque[T].physical_index(this.head, this.capacity, current - 1)
                    read(data_ptr + destination) = read(data_ptr + source)
                    current -= 1

            let target = Deque[T].physical_index(this.head, this.capacity, index)
            read(data_ptr + target) = value

        this.len += 1
        return true


    public editable function pop_back() -> Option[T]:
        if this.len == 0:
            return Option[T].none

        let data = this.data else:
            fatal(c"deque.pop_back missing storage")

        let tail_index = Deque[T].physical_index(this.head, this.capacity, this.len - 1)
        unsafe:
            let data_ptr = ptr[T]<-data
            let value = read(data_ptr + tail_index)
            if this.len == 1:
                this.head = 0
                this.len = 0
            else:
                this.len -= 1
            return Option[T].some(value = value)


    public editable function pop_front() -> Option[T]:
        if this.len == 0:
            return Option[T].none

        let data = this.data else:
            fatal(c"deque.pop_front missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            let value = read(data_ptr + this.head)
            if this.len == 1:
                this.head = 0
                this.len = 0
            else:
                this.len -= 1
                this.head = Deque[T].next_index(this.head, this.capacity)
            return Option[T].some(value = value)


    public editable function remove(index: ptr_uint) -> Option[T]:
        if index >= this.len:
            return Option[T].none

        if index == 0:
            return this.pop_front()

        if index + 1 == this.len:
            return this.pop_back()

        let data = this.data else:
            fatal(c"deque.remove missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            let removed_index = Deque[T].physical_index(this.head, this.capacity, index)
            let removed = read(data_ptr + removed_index)

            if index < this.len / 2:
                var current = index
                while current > 0:
                    let destination = Deque[T].physical_index(this.head, this.capacity, current)
                    let source = Deque[T].physical_index(this.head, this.capacity, current - 1)
                    read(data_ptr + destination) = read(data_ptr + source)
                    current -= 1
                this.head = Deque[T].next_index(this.head, this.capacity)
            else:
                var current = index
                while current + 1 < this.len:
                    let destination = Deque[T].physical_index(this.head, this.capacity, current)
                    let source = Deque[T].physical_index(this.head, this.capacity, current + 1)
                    read(data_ptr + destination) = read(data_ptr + source)
                    current += 1

            this.len -= 1
            return Option[T].some(value = removed)


    public editable function rotate_left(amount: ptr_uint) -> void:
        if this.len <= 1:
            return

        let shift = amount % this.len
        if shift == 0:
            return

        if shift > this.len - shift:
            this.rotate_right(this.len - shift)
            return

        var remaining = shift
        while remaining != 0:
            let rotated = this.pop_front()
            match rotated:
                Option.none:
                    fatal(c"deque.rotate_left missing front value")
                Option.some as payload:
                    this.push_back(payload.value)
            remaining -= 1


    public editable function rotate_right(amount: ptr_uint) -> void:
        if this.len <= 1:
            return

        let shift = amount % this.len
        if shift == 0:
            return

        if shift > this.len - shift:
            this.rotate_left(this.len - shift)
            return

        var remaining = shift
        while remaining != 0:
            let rotated = this.pop_back()
            match rotated:
                Option.none:
                    fatal(c"deque.rotate_right missing back value")
                Option.some as payload:
                    this.push_front(payload.value)
            remaining -= 1


extending Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public editable function next() -> ptr[T]?:
        if this.index >= this.len:
            return null

        let data = this.data else:
            fatal(c"deque.Iter.next missing storage")

        let current_index = this.index
        this.index += 1
        return unsafe: ptr[T]<-data + Deque[T].physical_index(this.head, this.capacity, current_index)
