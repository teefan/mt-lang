import std.deque as deque
import std.maybe as maybe


public struct Stack[T]:
    values: deque.Deque[T]


methods Stack[T]:
    public static function create() -> Stack[T]:
        return Stack[T](values = deque.Deque[T].create())


    public static function with_capacity(capacity: ptr_uint) -> Stack[T]:
        var result = Stack[T].create()
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
        return this.values.last()


    public editable function clear() -> void:
        this.values.clear()
        return


    public editable function release() -> void:
        this.values.release()
        return


    public editable function reserve(min_capacity: ptr_uint) -> void:
        this.values.reserve(min_capacity)
        return


    public editable function push(value: T) -> void:
        this.values.push_back(value)
        return


    public editable function pop() -> maybe.Maybe[T]:
        return this.values.pop_back()
