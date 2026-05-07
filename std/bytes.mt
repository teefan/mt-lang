module std.bytes

import std.vec as vec

pub struct Buffer:
    items: vec.Vec[ubyte]


pub def create() -> Buffer:
    return Buffer(items = vec.Vec[ubyte].create())


pub def with_capacity(capacity: ptr_uint) -> Buffer:
    return Buffer(items = vec.Vec[ubyte].with_capacity(capacity))


pub def count(buffer: Buffer) -> ptr_uint:
    return buffer.items.count()


pub def capacity(buffer: Buffer) -> ptr_uint:
    return buffer.items.capacity()


pub def is_empty(buffer: Buffer) -> bool:
    return buffer.items.is_empty()


pub def data_ptr(buffer: Buffer) -> ptr[ubyte]?:
    return buffer.items.data_ptr()


pub def as_span(buffer: Buffer) -> span[ubyte]:
    return buffer.items.as_span()


pub def clear(buffer: ref[Buffer]) -> void:
    buffer.items.clear()
    return


pub def release(buffer: ref[Buffer]) -> void:
    buffer.items.release()
    return


pub def try_reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> bool:
    return buffer.items.try_reserve(min_capacity)


pub def reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> void:
    buffer.items.reserve(min_capacity)
    return


pub def try_push(buffer: ref[Buffer], byte: ubyte) -> bool:
    return buffer.items.try_push(byte)


pub def push(buffer: ref[Buffer], byte: ubyte) -> void:
    buffer.items.push(byte)
    return


pub def get(buffer: Buffer, index: ptr_uint) -> ubyte:
    return buffer.items.get(index)


pub def set(buffer: ref[Buffer], index: ptr_uint, byte: ubyte) -> void:
    buffer.items.set(index, byte)
    return


pub def append(buffer: ref[Buffer], bytes: span[ubyte]) -> void:
    var index: ptr_uint = 0
    while index < bytes.len:
        unsafe:
            push(buffer, read(bytes.data + index))
        index += 1
    return
