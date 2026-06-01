import std.mem.heap as heap

## Explicit single-value heap storage.
##
## This is the intended escape hatch for shared mutable proc state.
## Allocation stays visible at the call site via `cell.alloc(...)`.
public struct Cell[T]:
    storage: ptr[T]?


public function alloc[T](value: T) -> Cell[T]:
    let storage = heap.must_alloc[T](1)
    unsafe:
        read(storage) = value
    return Cell[T](storage = storage)


extending Cell[T]:
    public function as_ptr() -> ptr[T]:
        let storage = this.storage else:
            fatal(c"cell.Cell.as_ptr released cell")

        return unsafe: ptr[T]<-storage


    public function get() -> T:
        unsafe:
            return read(this.as_ptr())


    public function set(value: T) -> void:
        unsafe:
            read(this.as_ptr()) = value


    public function replace(value: T) -> T:
        unsafe:
            let storage = this.as_ptr()
            let previous = read(storage)
            read(storage) = value
            return previous


    public function update(body: proc(value: T) -> T) -> T:
        let next = body(this.get())
        this.set(next)
        return next


    public function is_released() -> bool:
        return this.storage == null


    public mutable function release() -> void:
        heap.release(this.storage)
        this.storage = null
