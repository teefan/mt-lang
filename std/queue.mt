import std.deque as deque
import std.maybe as maybe


public struct Queue[T]:
    values: deque.Deque[T]


methods Queue[T]:
    public static function create() -> Queue[T]:
        return Queue[T](values = deque.Deque[T].create())


    public static function with_capacity(capacity: ptr_uint) -> Queue[T]:
        var result = Queue[T].create()
        result.reserve(capacity)
        return result


    public function len() -> ptr_uint:
        return this.values.len()


    public function capacity() -> ptr_uint:
        return this.values.capacity()


    public function is_empty() -> bool:
        return this.values.is_empty()


    public function iter() -> deque.Iter[T]:
        return this.values.iter()


    public function peek() -> ptr[T]?:
        return this.values.first()


    public editable function clear() -> void:
        this.values.clear()
        return


    public editable function release() -> void:
        this.values.release()
        return


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)
        return


    public editable function enqueue(value: T) -> void:
        this.values.push_back(value)
        return


    public editable function dequeue() -> maybe.Maybe[T]:
        return this.values.pop_front()
