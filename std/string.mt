module std.string

import std.mem.arena as arena
import std.mem.heap as heap

public struct String:
    data: ptr[ubyte]?
    len: ptr_uint
    capacity: ptr_uint

methods String:
    public static function create() -> String:
        return String(data = null, len = 0, capacity = 0)


    public static function with_capacity(capacity: ptr_uint) -> String:
        var result = String.create()
        result.reserve(capacity)
        return result


    public static function from_str(text: str) -> String:
        var result = String.with_capacity(text.len)
        result.append(text)
        return result


    public function count() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public editable function clear() -> void:
        this.len = 0
        return


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.len = 0
        this.capacity = 0
        return


    public editable function reserve(min_capacity: ptr_uint) -> void:
        if min_capacity <= this.capacity:
            return

        var new_capacity = this.capacity
        if new_capacity == 0:
            new_capacity = 4

        while new_capacity < min_capacity:
            if new_capacity > heap.ptr_uint_max() / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let resized = heap.resize[ubyte](this.data, new_capacity)
        if resized == null:
            fatal(c"string.reserve out of memory")

        this.data = resized
        this.capacity = new_capacity
        return


    public editable function push_byte(byte: ubyte) -> void:
        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data
        if data == null:
            fatal(c"string.push_byte missing storage")

        unsafe:
            let data_ptr = ptr[ubyte]<-data
            read(data_ptr + this.len) = byte
        this.len += 1
        return


    public editable function append(suffix: str) -> void:
        var index: ptr_uint = 0
        while index < suffix.len:
            unsafe: this.push_byte(ubyte<-read(suffix.data + index))
            index += 1
        return


    public editable function assign(value_text: str) -> void:
        this.clear()
        this.append(value_text)
        return


    public function as_str() -> str:
        let data = this.data
        if data == null and this.len != 0:
            fatal(c"string.as_str requires storage when len > 0")

        return unsafe: str(data = ptr[char]<-data, len = this.len)


    public function to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this.as_str())
