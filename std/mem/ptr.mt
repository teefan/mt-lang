## Pointer load/store — safe wrappers around unsafe: read(ptr).
##
##   import std.mem.ptr as ptr
##   p.store(42)
##   let v = p.load()

extending ptr[T]:
    public function load() -> T:
        return unsafe: read(this)

    public function store(value: T) -> void:
        unsafe: read(this) = value
