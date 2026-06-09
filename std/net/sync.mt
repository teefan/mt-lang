import std.vec as vec

public struct SyncValue[T]:
    value: T
    dirty: bool


extending SyncValue[T]:
    public editable function set(new_value: T) -> void:
        this.value = new_value
        this.dirty = true


    public function get() -> T:
        return this.value


    public editable function mark_clean() -> void:
        this.dirty = false


    public function has_changed() -> bool:
        return this.dirty


public struct SyncList[T]:
    items: vec.Vec[T]
    dirty: bool


extending SyncList[T]:
    public editable function push(item: T) -> void:
        this.items.push(item)
        this.dirty = true


    public editable function clear() -> void:
        this.items.clear()
        this.dirty = true


    public function len() -> ptr_uint:
        return this.items.len()


    public function get(index: ptr_uint) -> ptr[T]?:
        return this.items.get(index)


    public editable function mark_clean() -> void:
        this.dirty = false


    public function has_changed() -> bool:
        return this.dirty
