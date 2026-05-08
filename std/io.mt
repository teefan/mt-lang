module std.io

import std.fmt as fmt
import std.c.unistd as unistd
import std.string as string

const stdout_fd: int = 1
const stderr_fd: int = 2


function write_fd(fd: int, text: str) -> bool:
    if text.len == 0:
        return true

    unsafe:
        let written = unistd.write(fd, ptr[void]<-text.data, text.len)
        return written == long<-text.len


public function write(text: str) -> bool:
    return write_fd(stdout_fd, text)


public function write_line(text: str) -> bool:
    if not write(text):
        return false
    return write("\n")


public function write_error(text: str) -> bool:
    return write_fd(stderr_fd, text)


public function write_error_line(text: str) -> bool:
    if not write_error(text):
        return false
    return write_error("\n")


public function print(text: str) -> bool:
    return write(text)


public function println(text: str) -> bool:
    return write_line(text)


function print_formatted(text: ref[string.String]) -> bool:
    let ok = write(text.as_str())
    text.release()
    return ok


function println_formatted(text: ref[string.String]) -> bool:
    let ok = write_line(text.as_str())
    text.release()
    return ok


function write_error_formatted(text: ref[string.String]) -> bool:
    let ok = write_error(text.as_str())
    text.release()
    return ok


function write_error_line_formatted(text: ref[string.String]) -> bool:
    let ok = write_error_line(text.as_str())
    text.release()
    return ok
