import std.map
import std.str
import std.vec

public type IdentId = ptr_uint

public struct Interner:
    table: map.Map[str, ptr_uint]
    strings: vec.Vec[str]


public function create() -> Interner:
    return Interner(
        table = map.Map[str, ptr_uint].create(),
        strings = vec.Vec[str].create()
    )


public function with_capacity(capacity: ptr_uint) -> Interner:
    return Interner(
        table = map.Map[str, ptr_uint].with_capacity(capacity),
        strings = vec.Vec[str].with_capacity(capacity)
    )


extending Interner:
    public function len() -> ptr_uint:
        return this.strings.len


    public editable function intern(text: str) -> ptr_uint:
        let existing = this.table.get(text) else:
            let id = this.strings.len
            this.strings.push(text)
            let _ = this.table.set(text, id)
            return id

        unsafe:
            return read(existing)


    public function lookup(id: ptr_uint) -> Option[str]:
        return this.strings.at(id)


    public editable function clear() -> void:
        this.table.clear()
        this.strings.clear()


    public editable function release() -> void:
        this.table.release()
        this.strings.release()
