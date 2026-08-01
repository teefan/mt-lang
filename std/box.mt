import std.mem.heap as heap

## Explicit single-value heap storage.
##
## This is the intended escape hatch for shared mutable proc state.
## Allocation stays visible at the call site via `box.alloc(...)`.
public struct Box[T]:
    storage: own[T]?


public function alloc[T](value: T) -> Box[T]:
    let storage = heap.must_alloc[T](1)
    read(storage) = value
    return Box[T](storage = storage)


extending Box[T]:
    public function as_ptr() -> ptr[T]:
        let storage = this.storage else:
            fatal(c"box.Box.as_ptr released box")

        return storage


    public function get() -> T:
        let storage = this.storage else:
            fatal(c"box.Box.get released box")

        return read(storage)


    public function set(value: T) -> void:
        let storage = this.storage else:
            fatal(c"box.Box.set released box")

        read(storage) = value


    public function replace(value: T) -> T:
        let storage = this.storage else:
            fatal(c"box.Box.replace released box")

        let previous = read(storage)
        read(storage) = value
        return previous


    public function update(body: proc(value: T) -> T) -> T:
        let next = body(this.get())
        this.set(next)
        return next


    public function is_released() -> bool:
        return this.storage == null


    public editable function release() -> void:
        heap.release(this.storage)
        this.storage = null
