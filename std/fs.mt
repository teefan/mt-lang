module std.fs

import std.bytes as bytes
import std.c.stdio as c
import std.mem.arena as arena
import std.span as sp
import std.str as text
import std.string as string

pub enum Error: u8
    open_failed = 1
    read_failed = 2
    write_failed = 3
    close_failed = 4
    invalid_utf8 = 5

pub def exists(path: str, scratch: ref[arena.Arena]) -> bool:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_path = scratch.to_cstr(path)
    let file = c.fopen(c_path, c"rb")
    if file == null:
        return false

    c.fclose(file)
    return true

pub def read_bytes(path: str, scratch: ref[arena.Arena]) -> Result[bytes.Buffer, Error]:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_path = scratch.to_cstr(path)
    let file = c.fopen(c_path, c"rb")
    if file == null:
        return err(Error.open_failed)

    var result = bytes.create()
    var done = false
    while not done:
        let ch = c.fgetc(file)
        if ch == c.EOF:
            done = true
        else:
            bytes.push(ref_of(result), u8<-ch)

    if c.ferror(file) != 0:
        bytes.release(ref_of(result))
        c.fclose(file)
        return err(Error.read_failed)

    if c.fclose(file) != 0:
        bytes.release(ref_of(result))
        return err(Error.close_failed)

    return ok(result)

pub def read_text(path: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    let loaded = read_bytes(path, scratch)
    if not loaded.is_ok:
        return err(loaded.error)

    var data = loaded.value
    let view = bytes.as_span(data)
    unsafe:
        let borrowed = str(data = ptr[char]<-view.data, len = view.len)
        if not text.is_valid_utf8(borrowed):
            bytes.release(ref_of(data))
            return err(Error.invalid_utf8)

        var result = string.String.with_capacity(borrowed.len)
        result.append(borrowed)
        bytes.release(ref_of(data))
        return ok(result)

pub def write_bytes(path: str, data: span[u8], scratch: ref[arena.Arena]) -> Result[bool, Error]:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_path = scratch.to_cstr(path)
    let file = c.fopen(c_path, c"wb")
    if file == null:
        return err(Error.open_failed)

    var index: usize = 0
    while index < data.len:
        unsafe:
            if c.fputc(i32<-read(data.data + index), file) == c.EOF:
                c.fclose(file)
                return err(Error.write_failed)
        index += 1

    if c.fclose(file) != 0:
        return err(Error.close_failed)

    return ok(true)

pub def write_text(path: str, data: str, scratch: ref[arena.Arena]) -> Result[bool, Error]:
    unsafe:
        let bytes_view = sp.from_ptr[u8](ptr[u8]<-data.data, data.len)
        return write_bytes(path, bytes_view, scratch)