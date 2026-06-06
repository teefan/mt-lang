import std.binary_heap as binary_heap

public struct PriorityQueue[T]:
    values: binary_heap.BinaryHeap[T]


extending PriorityQueue[T]:
    public static function create() -> PriorityQueue[T]:
        return PriorityQueue[T](values = binary_heap.BinaryHeap[T].create())


    public static function with_capacity(capacity: ptr_uint) -> PriorityQueue[T]:
        var result = PriorityQueue[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function iter() -> binary_heap.Iter[T]:
        return this.values.iter()


    public function peek() -> const_ptr[T]?:
        return this.values.peek()


    public editable function clear() -> void:
        this.values.clear()


    public editable function release() -> void:
        this.values.release()


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)


    public editable function enqueue(value: T) -> void:
        this.values.push(value)


    public editable function dequeue() -> Option[T]:
        return this.values.pop()
