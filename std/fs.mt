module std.fs

import std.bytes as bytes
import std.option as option
import std.stdio as c
import std.str as text
import std.string as string

pub enum Error: ubyte
    open_failed = 1
    read_failed = 2
    write_failed = 3
    close_failed = 4
    invalid_utf8 = 5


pub def exists(path: str) -> bool:
    let file = c.open(path, "rb")
    if file == null:
        return false

    c.close(file)
    return true


pub def read_bytes(path: str) -> Result[bytes.Buffer, Error]:
    let file = c.open(path, "rb")
    if file == null:
        return err(Error.open_failed)

    var result = bytes.create()
    var done = false
    while not done:
        let ch = c.get_char(file)
        if ch == c.EOF:
            done = true
        else:
            bytes.push(ref_of(result), ubyte<-ch)

    if c.error(file) != 0:
        bytes.release(ref_of(result))
        c.close(file)
        return err(Error.read_failed)

    if c.close(file) != 0:
        bytes.release(ref_of(result))
        return err(Error.close_failed)

    return ok(result)


pub def read_text(path: str) -> Result[string.String, Error]:
    let loaded = read_bytes(path)
    if not loaded.is_ok:
        return err(loaded.error)

    var data = loaded.value
    let view = bytes.as_span(data)
    let borrowed: option.Option[str] = text.utf8_byte_span_as_str(view)
    if borrowed.is_none():
        bytes.release(ref_of(data))
        return err(Error.invalid_utf8)

    let borrowed_text = borrowed.unwrap()
    var result = string.String.with_capacity(borrowed_text.len)
    result.append(borrowed_text)
    bytes.release(ref_of(data))
    return ok(result)


pub def write_bytes(path: str, data: span[ubyte]) -> Result[bool, Error]:
    let file = c.open(path, "wb")
    if file == null:
        return err(Error.open_failed)

    var index: ptr_uint = 0
    while index < data.len:
        unsafe:
            if c.put_char(int<-read(data.data + index), file) == c.EOF:
                c.close(file)
                return err(Error.write_failed)
        index += 1

    if c.close(file) != 0:
        return err(Error.close_failed)

    return ok(true)


pub def write_text(path: str, data: str) -> Result[bool, Error]:
    return write_bytes(path, text.as_byte_span(data))
