module std.string

import std.bytes as bytes
import std.mem.arena as arena

pub struct String:
    buffer: bytes.Buffer

pub def create() -> String:
    return String(buffer = bytes.create())

pub def with_capacity(capacity: usize) -> String:
    return String(buffer = bytes.with_capacity(capacity))

pub def from_str(text: str) -> String:
    var result = with_capacity(text.len)
    append(addr(result), text)
    return result

pub def count(text: String) -> usize:
    return bytes.count(text.buffer)

pub def capacity(text: String) -> usize:
    return bytes.capacity(text.buffer)

pub def is_empty(text: String) -> bool:
    return bytes.is_empty(text.buffer)

pub def clear(text: ref[String]) -> void:
    bytes.clear(addr(value(text).buffer))
    return

pub def release(text: ref[String]) -> void:
    bytes.release(addr(value(text).buffer))
    return

pub def reserve(text: ref[String], min_capacity: usize) -> void:
    bytes.reserve(addr(value(text).buffer), min_capacity)
    return

pub def push_byte(text: ref[String], byte: u8) -> void:
    bytes.push(addr(value(text).buffer), byte)
    return

pub def append(text: ref[String], suffix: str) -> void:
    var index: usize = 0
    while index < suffix.len:
        unsafe:
            push_byte(text, cast[u8](deref(suffix.data + index)))
        index += 1
    return

pub def assign(text: ref[String], value_text: str) -> void:
    clear(text)
    append(text, value_text)
    return

pub def as_str(text: String) -> str:
    let data = bytes.data_ptr(text.buffer)
    unsafe:
        return str(data = cast[ptr[char]](data), len = bytes.count(text.buffer))

pub def to_cstr(text: String, space: ref[arena.Arena]) -> cstr:
    return value(space).to_cstr(as_str(text))
