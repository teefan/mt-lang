module std.string

import std.bytes as bytes
import std.mem.arena as arena

public struct String:
    buffer: bytes.Buffer

methods String:
    public static function create() -> String:
        return String(buffer = bytes.create())


    public static function with_capacity(capacity: ptr_uint) -> String:
        return String(buffer = bytes.with_capacity(capacity))


    public static function from_str(text: str) -> String:
        var result = String(buffer = bytes.with_capacity(text.len))
        result.append(text)
        return result


    public function count() -> ptr_uint:
        return bytes.count(this.buffer)


    public function capacity() -> ptr_uint:
        return bytes.capacity(this.buffer)


    public function is_empty() -> bool:
        return bytes.is_empty(this.buffer)


    public edit function clear() -> void:
        bytes.clear(ref_of(this.buffer))
        return


    public edit function release() -> void:
        bytes.release(ref_of(this.buffer))
        return


    public edit function reserve(min_capacity: ptr_uint) -> void:
        bytes.reserve(ref_of(this.buffer), min_capacity)
        return


    public edit function push_byte(byte: ubyte) -> void:
        bytes.push(ref_of(this.buffer), byte)
        return


    public edit function append(suffix: str) -> void:
        var index: ptr_uint = 0
        while index < suffix.len:
            unsafe: this.push_byte(ubyte<-read(suffix.data + index))
            index += 1
        return


    public edit function assign(value_text: str) -> void:
        this.clear()
        this.append(value_text)
        return


    public function as_str() -> str:
        let data = bytes.data_ptr(this.buffer)
        return unsafe: str(data = ptr[char]<-data, len = bytes.count(this.buffer))


    public function to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this.as_str())
