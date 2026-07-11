import std.mem.heap as heap

## Explicit single-value heap storage.
##
## This is the intended escape hatch for shared mutable proc state.
## Allocation stays visible at the call site via `cell.alloc(...)`.
public struct Cell[T]:
    storage: own[T]?


public function alloc[T](value: T) -> Cell[T]:
    let storage = heap.must_alloc[T](1)
    read(storage) = value
    return Cell[T](storage = storage)


extending Cell[T]:
    public function as_ptr() -> ptr[T]:
        let storage = this.storage else:
            fatal(c"cell.Cell.as_ptr released cell")

        return storage


    public function get() -> T:
        let storage = this.storage else:
            fatal(c"cell.Cell.get released cell")

        return read(storage)


    public function set(value: T) -> void:
        let storage = this.storage else:
            fatal(c"cell.Cell.set released cell")

        read(storage) = value


    public function replace(value: T) -> T:
        let storage = this.storage else:
            fatal(c"cell.Cell.replace released cell")

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
