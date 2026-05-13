module std.bytes

import std.mem.heap as heap
import std.maybe as maybe
import std.str as text


public struct Bytes:
    data: ptr[ubyte]?
    len: ptr_uint


methods Bytes:
    public static function empty() -> Bytes:
        return Bytes(data = null, len = 0)


    public static function copy(source: span[ubyte]) -> Bytes:
        if source.len == 0:
            return Bytes.empty()

        let data = heap.must_alloc[ubyte](source.len)
        var index: ptr_uint = 0
        while index < source.len:
            unsafe:
                read(data + index) = read(source.data + index)
            index += 1

        return Bytes(data = data, len = source.len)


    public editable function release() -> void:
        heap.release(this.data)
        this.data = null
        this.len = 0
        return


    public function as_span() -> span[ubyte]:
        if this.data == null and this.len != 0:
            fatal(c"bytes.Bytes.as_span missing storage")

        return unsafe: span[ubyte](data = ptr[ubyte]<-this.data, len = this.len)


    public function as_str() -> maybe.Maybe[str]:
        return text.utf8_byte_span_as_str(this.as_span())
