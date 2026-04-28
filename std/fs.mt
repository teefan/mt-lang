module std.fs

import std.bytes as bytes
import std.c.stdio as c
import std.mem.arena as arena

pub enum Error: u8
    open_failed = 1
    read_failed = 2
    write_failed = 3
    close_failed = 4

pub def exists(path: str, scratch: ref[arena.Arena]) -> bool:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_path = value(scratch).to_cstr(path)
    let file = c.fopen(c_path, c"rb")
    if file == null:
        return false

    c.fclose(file)
    return true

pub def read_bytes(path: str, scratch: ref[arena.Arena]) -> Result[bytes.Buffer, Error]:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_path = value(scratch).to_cstr(path)
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
            bytes.push(addr(result), cast[u8](ch))

    if c.ferror(file) != 0:
        bytes.release(addr(result))
        c.fclose(file)
        return err(Error.read_failed)

    if c.fclose(file) != 0:
        bytes.release(addr(result))
        return err(Error.close_failed)

    return ok(result)

pub def write_bytes(path: str, data: span[u8], scratch: ref[arena.Arena]) -> Result[bool, Error]:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_path = value(scratch).to_cstr(path)
    let file = c.fopen(c_path, c"wb")
    if file == null:
        return err(Error.open_failed)

    var index: usize = 0
    while index < data.len:
        unsafe:
            if c.fputc(cast[i32](deref(data.data + index)), file) == c.EOF:
                c.fclose(file)
                return err(Error.write_failed)
        index += 1

    if c.fclose(file) != 0:
        return err(Error.close_failed)

    return ok(true)
