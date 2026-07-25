import std.mem.heap as heap

public struct RingBuffer[T]:
    data: own[T]?
    head: ptr_uint
    len: ptr_uint
    capacity: ptr_uint

public struct Iter[T]:
    data: ptr[T]?
    head: ptr_uint
    len: ptr_uint
    capacity: ptr_uint
    index: ptr_uint


extending RingBuffer[T]:
    public static function with_capacity(capacity: ptr_uint) -> RingBuffer[T]:
        let data = heap.must_alloc[T](capacity)
        return RingBuffer[T](data = data, head = 0, len = 0, capacity = capacity)


    static function physical_index(head: ptr_uint, capacity: ptr_uint, index: ptr_uint) -> ptr_uint:
        let raw = head + index
        if raw >= capacity:
            return raw - capacity

        return raw


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public function is_full() -> bool:
        return this.len == this.capacity


    public function iter() -> Iter[T]:
        return Iter[T](data = this.data, head = this.head, len = this.len, capacity = this.capacity, index = 0)


    public function get(index: ptr_uint) -> ptr[T]?:
        if index >= this.len:
            return null

        let data = this.data else:
            fatal(c"ring_buffer.RingBuffer.get missing storage")

        return unsafe: ptr[T]<-data + RingBuffer[T].physical_index(this.head, this.capacity, index)


    public function at(index: ptr_uint) -> Option[T]:
        let p = this.get(index) else:
            return Option[T].none

        unsafe:
            return Option[T].some(value = read(p))


    public function peek() -> ptr[T]?:
        return this.get(0)


    public editable function push(value: T) -> void:
        let data = this.data else:
            fatal(c"ring_buffer.RingBuffer.push missing storage")

        let tail = RingBuffer[T].physical_index(this.head, this.capacity, this.len)

        unsafe:
            let data_ptr = ptr[T]<-data
            read(data_ptr + tail) = value

        if this.len == this.capacity:
            this.head = RingBuffer[T].physical_index(this.head, this.capacity, 1)
        else:
            this.len += 1


    public editable function pop() -> Option[T]:
        if this.len == 0:
            return Option[T].none

        let data = this.data else:
            fatal(c"ring_buffer.RingBuffer.pop missing storage")

        unsafe:
            let data_ptr = ptr[T]<-data
            let value = read(data_ptr + this.head)
            this.head = RingBuffer[T].physical_index(this.head, this.capacity, 1)
            this.len -= 1
            return Option[T].some(value = value)


    public editable function clear() -> void:
        this.head = 0
        this.len = 0


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.head = 0
        this.len = 0
        this.capacity = 0


extending Iter[T]:
    public function iter() -> Iter[T]:
        return this


    public editable function next() -> ptr[T]?:
        if this.index >= this.len:
            return null

        let data = this.data else:
            fatal(c"ring_buffer.Iter.next missing storage")

        let current_index = this.index
        this.index += 1
        return unsafe: ptr[T]<-data + RingBuffer[T].physical_index(this.head, this.capacity, current_index)
