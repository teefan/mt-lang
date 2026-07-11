import std.mem.heap as heap
import std.str as text

public struct Bytes:
    data: own[ubyte]?
    len: ptr_uint


extending Bytes:
    public static function empty() -> Bytes:
        return Bytes(data = null, len = 0)


    public static function copy(source: span[ubyte]) -> Bytes:
        if source.len == 0:
            return Bytes.empty()

        let data = heap.must_alloc[ubyte](source.len)
        heap.copy_bytes(data, source.data, source.len)

        return Bytes(data = data, len = source.len)


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.len = 0


    public function as_span() -> span[ubyte]:
        let data = this.data else:
            return span[ubyte](data = zero[ptr[ubyte]], len = 0)

        return span[ubyte](data = data, len = this.len)


    public function as_str() -> Option[str]:
        return text.utf8_byte_span_as_str(this.as_span())
