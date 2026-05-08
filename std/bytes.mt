module std.bytes

import std.vec as vec

public struct Buffer:
    items: vec.Vec[ubyte]


public function create() -> Buffer:
    return Buffer(items = vec.Vec[ubyte].create())


public function with_capacity(capacity: ptr_uint) -> Buffer:
    return Buffer(items = vec.Vec[ubyte].with_capacity(capacity))


public function count(buffer: Buffer) -> ptr_uint:
    return buffer.items.count()


public function capacity(buffer: Buffer) -> ptr_uint:
    return buffer.items.capacity()


public function is_empty(buffer: Buffer) -> bool:
    return buffer.items.is_empty()


public function data_ptr(buffer: Buffer) -> ptr[ubyte]?:
    return buffer.items.data_ptr()


public function as_span(buffer: Buffer) -> span[ubyte]:
    return buffer.items.as_span()


public function clear(buffer: ref[Buffer]) -> void:
    buffer.items.clear()
    return


public function release(buffer: ref[Buffer]) -> void:
    buffer.items.release()
    return


public function try_reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> bool:
    return buffer.items.try_reserve(min_capacity)


public function reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> void:
    buffer.items.reserve(min_capacity)
    return


public function try_push(buffer: ref[Buffer], byte: ubyte) -> bool:
    return buffer.items.try_push(byte)


public function push(buffer: ref[Buffer], byte: ubyte) -> void:
    buffer.items.push(byte)
    return


public function get(buffer: Buffer, index: ptr_uint) -> ubyte:
    return buffer.items.get(index)


public function set(buffer: ref[Buffer], index: ptr_uint, byte: ubyte) -> void:
    buffer.items.set(index, byte)
    return


public function append(buffer: ref[Buffer], bytes: span[ubyte]) -> void:
    var index: ptr_uint = 0
    while index < bytes.len:
        unsafe:
            push(buffer, read(bytes.data + index))
        index += 1
    return
