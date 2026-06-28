import std.str
import std.string as string
import std.vec as vec

public struct Interner:
    entries: vec.Vec[string.String]

extending Interner:
    public static function create() -> Interner:
        return Interner(entries = vec.Vec[string.String].create())

    public editable function intern(text: str) -> str:
        var iter = this.entries.iter()
        while true:
            let entry_ptr = iter.next() else:
                break
            unsafe:
                let entry = read(entry_ptr)
                if entry.as_str().equal(text):
                    return entry.as_str()

        let owned = string.String.from_str(text)
        this.entries.push(owned)
        let last_ptr = this.entries.last() else:
            fatal(c"interner.intern missing entry")
        unsafe:
            return read(last_ptr).as_str()

    public function len() -> ptr_uint:
        return this.entries.len()

    public editable function release() -> void:
        var i: ptr_uint = 0
        while i < this.entries.len():
            let entry_ptr = this.entries.get(i) else:
                fatal(c"interner.release missing entry")
            unsafe:
                read(entry_ptr).release()
            i += 1
        this.entries.release()
