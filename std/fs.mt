module std.fs

import std.bytes as bytes
import std.maybe as maybe
import std.status as status
import std.stdio as c
import std.str as text
import std.string as string

public enum Error: ubyte
    open_failed = 1
    read_failed = 2
    write_failed = 3
    close_failed = 4
    invalid_utf8 = 5


public function exists(path: str) -> bool:
    let file = c.open(path, "rb")
    if file == null:
        return false

    c.close(file)
    return true


public function read_bytes(path: str) -> status.Status[bytes.Buffer, Error]:
    let file = c.open(path, "rb")
    if file == null:
        return status.Status[bytes.Buffer, Error].err(error= Error.open_failed)

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
        return status.Status[bytes.Buffer, Error].err(error= Error.read_failed)

    if c.close(file) != 0:
        bytes.release(ref_of(result))
        return status.Status[bytes.Buffer, Error].err(error= Error.close_failed)

    return status.Status[bytes.Buffer, Error].ok(value= result)


public function read_text(path: str) -> status.Status[string.String, Error]:
    let loaded = read_bytes(path)
    match loaded:
        status.Status.err as payload:
            return status.Status[string.String, Error].err(error= payload.error)
        status.Status.ok as loaded_payload:
            var data = loaded_payload.value
            let view = bytes.as_span(data)
            let borrowed: maybe.Maybe[str] = text.utf8_byte_span_as_str(view)
            match borrowed:
                maybe.Maybe.none:
                    bytes.release(ref_of(data))
                    return status.Status[string.String, Error].err(error= Error.invalid_utf8)
                maybe.Maybe.some as borrowed_payload:
                    let borrowed_text = borrowed_payload.value
                    var result = string.String.with_capacity(borrowed_text.len)
                    result.append(borrowed_text)
                    bytes.release(ref_of(data))
                    return status.Status[string.String, Error].ok(value= result)


public function write_bytes(path: str, data: span[ubyte]) -> status.Status[bool, Error]:
    let file = c.open(path, "wb")
    if file == null:
        return status.Status[bool, Error].err(error= Error.open_failed)

    var index: ptr_uint = 0
    while index < data.len:
        unsafe:
            if c.put_char(int<-read(data.data + index), file) == c.EOF:
                c.close(file)
                return status.Status[bool, Error].err(error= Error.write_failed)
        index += 1

    if c.close(file) != 0:
        return status.Status[bool, Error].err(error= Error.close_failed)

    return status.Status[bool, Error].ok(value= true)


public function write_text(path: str, data: str) -> status.Status[bool, Error]:
    return write_bytes(path, text.as_byte_span(data))
