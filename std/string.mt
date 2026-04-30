module std.string

import std.bytes as bytes
import std.mem.arena as arena

pub struct String:
    buffer: bytes.Buffer

methods String:
    pub static def create() -> String:
        return String(buffer = bytes.create())

    pub static def with_capacity(capacity: usize) -> String:
        return String(buffer = bytes.with_capacity(capacity))

    pub static def from_str(text: str) -> String:
        var result = String(buffer = bytes.with_capacity(text.len))
        result.append(text)
        return result

    pub def count() -> usize:
        return bytes.count(this.buffer)

    pub def capacity() -> usize:
        return bytes.capacity(this.buffer)

    pub def is_empty() -> bool:
        return bytes.is_empty(this.buffer)

    pub edit def clear() -> void:
        bytes.clear(ref_of(this.buffer))
        return

    pub edit def release() -> void:
        bytes.release(ref_of(this.buffer))
        return

    pub edit def reserve(min_capacity: usize) -> void:
        bytes.reserve(ref_of(this.buffer), min_capacity)
        return

    pub edit def push_byte(byte: u8) -> void:
        bytes.push(ref_of(this.buffer), byte)
        return

    pub edit def append(suffix: str) -> void:
        var index: usize = 0
        while index < suffix.len:
            unsafe:
                this.push_byte(u8<-read(suffix.data + index))
            index += 1
        return

    pub edit def assign(value_text: str) -> void:
        this.clear()
        this.append(value_text)
        return

    pub def as_str() -> str:
        let data = bytes.data_ptr(this.buffer)
        unsafe:
            return str(data = ptr[char]<-data, len = bytes.count(this.buffer))

    pub def to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this.as_str())
