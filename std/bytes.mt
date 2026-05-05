module std.bytes

import std.vec as vec

pub struct Buffer:
    items: vec.Vec[ubyte]


pub def create() -> Buffer:
    return Buffer(items = vec.create[ubyte]())


pub def with_capacity(capacity: ptr_uint) -> Buffer:
    return Buffer(items = vec.with_capacity[ubyte](capacity))


pub def count(buffer: Buffer) -> ptr_uint:
    return vec.count[ubyte](buffer.items)


pub def capacity(buffer: Buffer) -> ptr_uint:
    return vec.capacity[ubyte](buffer.items)


pub def is_empty(buffer: Buffer) -> bool:
    return vec.is_empty[ubyte](buffer.items)


pub def data_ptr(buffer: Buffer) -> ptr[ubyte]?:
    return vec.data_ptr[ubyte](buffer.items)


pub def as_span(buffer: Buffer) -> span[ubyte]:
    return vec.as_span[ubyte](buffer.items)


pub def clear(buffer: ref[Buffer]) -> void:
    vec.clear[ubyte](ref_of(buffer.items))
    return


pub def release(buffer: ref[Buffer]) -> void:
    vec.release[ubyte](ref_of(buffer.items))
    return


pub def try_reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> bool:
    return vec.try_reserve[ubyte](ref_of(buffer.items), min_capacity)


pub def reserve(buffer: ref[Buffer], min_capacity: ptr_uint) -> void:
    vec.reserve[ubyte](ref_of(buffer.items), min_capacity)
    return


pub def try_push(buffer: ref[Buffer], byte: ubyte) -> bool:
    return vec.try_push[ubyte](ref_of(buffer.items), byte)


pub def push(buffer: ref[Buffer], byte: ubyte) -> void:
    vec.push[ubyte](ref_of(buffer.items), byte)
    return


pub def get(buffer: Buffer, index: ptr_uint) -> ubyte:
    return vec.get[ubyte](buffer.items, index)


pub def set(buffer: ref[Buffer], index: ptr_uint, byte: ubyte) -> void:
    vec.set[ubyte](ref_of(buffer.items), index, byte)
    return


pub def append(buffer: ref[Buffer], bytes: span[ubyte]) -> void:
    var index: ptr_uint = 0
    while index < bytes.len:
        unsafe:
            push(buffer, read(bytes.data + index))
        index += 1
    return
