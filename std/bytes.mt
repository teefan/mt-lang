module std.bytes

import std.vec as vec

pub struct Buffer:
    items: vec.Vec[u8]

pub def create() -> Buffer:
    return Buffer(items = vec.create[u8]())

pub def with_capacity(capacity: usize) -> Buffer:
    return Buffer(items = vec.with_capacity[u8](capacity))

pub def count(buffer: Buffer) -> usize:
    return vec.count[u8](buffer.items)

pub def capacity(buffer: Buffer) -> usize:
    return vec.capacity[u8](buffer.items)

pub def is_empty(buffer: Buffer) -> bool:
    return vec.is_empty[u8](buffer.items)

pub def data_ptr(buffer: Buffer) -> ptr[u8]?:
    return vec.data_ptr[u8](buffer.items)

pub def as_span(buffer: Buffer) -> span[u8]:
    return vec.as_span[u8](buffer.items)

pub def clear(buffer: ref[Buffer]) -> void:
    vec.clear[u8](ref_of(buffer.items))
    return

pub def release(buffer: ref[Buffer]) -> void:
    vec.release[u8](ref_of(buffer.items))
    return

pub def try_reserve(buffer: ref[Buffer], min_capacity: usize) -> bool:
    return vec.try_reserve[u8](ref_of(buffer.items), min_capacity)

pub def reserve(buffer: ref[Buffer], min_capacity: usize) -> void:
    vec.reserve[u8](ref_of(buffer.items), min_capacity)
    return

pub def try_push(buffer: ref[Buffer], byte: u8) -> bool:
    return vec.try_push[u8](ref_of(buffer.items), byte)

pub def push(buffer: ref[Buffer], byte: u8) -> void:
    vec.push[u8](ref_of(buffer.items), byte)
    return

pub def get(buffer: Buffer, index: usize) -> u8:
    return vec.get[u8](buffer.items, index)

pub def set(buffer: ref[Buffer], index: usize, byte: u8) -> void:
    vec.set[u8](ref_of(buffer.items), index, byte)
    return

pub def append(buffer: ref[Buffer], bytes: span[u8]) -> void:
    var index: usize = 0
    while index < bytes.len:
        unsafe:
            push(buffer, read(bytes.data + index))
        index += 1
    return
