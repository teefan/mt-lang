import std.str as text_ops
import std.mem.arena as arena
import std.mem.heap as heap

public struct String:
    data: ptr[ubyte]?
    len: ptr_uint
    capacity: ptr_uint
    owns_storage: bool


extending String:
    public static function create() -> String:
        return String(data = null, len = 0, capacity = 0, owns_storage = true)


    public static function with_capacity(capacity: ptr_uint) -> String:
        var result = String.create()
        result.reserve(capacity)
        return result


    public static function from_str(text: str) -> String:
        var result = String.with_capacity(text.len)
        result.append(text)
        return result


    public function len() -> ptr_uint:
        return this.len


    public function capacity() -> ptr_uint:
        return this.capacity


    public function is_empty() -> bool:
        return this.len == 0


    public mutable function clear() -> void:
        this.len = 0


    public mutable function truncate(new_len: ptr_uint) -> void:
        if new_len > this.len:
            fatal(c"string.truncate new length exceeds current length")
        this.len = new_len


    public mutable function release() -> void:
        if this.owns_storage:
            heap.release(this.data)

        this.data = null
        this.len = 0
        this.capacity = 0
        this.owns_storage = true


    public static function hash(value: const_ptr[String]) -> uint:
        let fnv_offset: uint = 0x811C9DC5
        let fnv_prime: uint = 0x01000193

        unsafe:
            let view = read(value)
            var result = fnv_offset
            let raw = view.as_str()
            var index: ptr_uint = 0
            while index < raw.len:
                let byte_value = uint<-raw.byte_at(index)
                result = (result ^ byte_value) * fnv_prime
                index += 1
            return result


    public static function equal(left: const_ptr[String], right: const_ptr[String]) -> bool:
        unsafe:
            let left_view = read(left)
            let right_view = read(right)
            return left_view.as_str().equal(right_view.as_str())


    public mutable function reserve(min_capacity: ptr_uint) -> void:
        if min_capacity <= this.capacity:
            return

        if not this.owns_storage:
            fatal(c"string.reserve cannot grow borrowed storage")

        var new_capacity = this.capacity
        if new_capacity == 0:
            new_capacity = 4

        while new_capacity < min_capacity:
            if new_capacity > heap.ptr_uint_max / 2:
                new_capacity = min_capacity
            else:
                new_capacity *= 2

        let resized = heap.resize[ubyte](this.data, new_capacity) else:
            fatal(c"string.reserve out of memory")

        this.data = resized
        this.capacity = new_capacity


    public mutable function push_byte(value: ubyte) -> void:
        if this.len == this.capacity:
            this.reserve(this.len + 1)

        let data = this.data else:
            fatal(c"string.push_byte missing storage")

        unsafe:
            let data_ptr = ptr[ubyte]<-data
            read(data_ptr + this.len) = value
        this.len += 1


    public mutable function append(suffix: str) -> void:
        if suffix.len == 0:
            return

        let current_len = this.len
        if suffix.len > heap.ptr_uint_max - current_len:
            fatal(c"string.append size overflow")

        let new_len = current_len + suffix.len
        let needs_growth = new_len > this.capacity

        var copied: ptr[ubyte]? = null
        if needs_growth:
            copied = heap.must_alloc[ubyte](suffix.len)
            unsafe: heap.copy_bytes(copied, ptr[ubyte]<-suffix.data, suffix.len)

        this.reserve(new_len)

        let data = this.data else:
            fatal(c"string.append missing storage")

        unsafe:
            let destination = ptr[ubyte]<-data + current_len
            if copied != null:
                heap.copy_bytes(destination, copied, suffix.len)
                heap.release(copied)
            else:
                heap.copy_bytes(destination, ptr[ubyte]<-suffix.data, suffix.len)

        this.len = new_len


    public mutable function append_format(text: str) -> void:
        this.append(text)


    public mutable function assign(value_text: str) -> void:
        this.clear()
        this.append(value_text)


    public mutable function assign_format(text: str) -> void:
        this.assign(text)


    public function as_str() -> str:
        let data = this.data
        if data == null and this.len != 0:
            fatal(c"string.as_str requires storage when len > 0")

        let borrowed = unsafe: str(data = ptr[char]<-data, len = this.len)
        if not borrowed.is_valid_utf8():
            fatal(c"string.as_str text must be valid UTF-8")

        return borrowed


    public function to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this.as_str())
